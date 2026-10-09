#!/usr/bin/env node
/**
 * p2-selftest.mjs —— 在桌面上预演 iOS P2 的整条链路（**不下载、不碰真源**）
 *
 * 它复刻 iOS 端的行为：
 *   BootstrapLoader  把 App 内置的 bootstrap.js + 打桩 bundle 落到沙箱数据目录
 *   NodeRuntime      起 /msg 桥（带 X-CatVod-Token）→ node <bootstrap.js> <argv…>
 *   BridgeServer     收 serverStarted
 *   客户端侧          GET /config /config/sites/list /spider/demo/3 …
 *
 * 用法: node tools/host/p2-selftest.mjs
 * 通过标准: 打印 "✓ P2 链路自检通过"
 */

import { spawn } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { copyFileSync, existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import http from 'node:http'
import net from 'node:net'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO = resolve(HERE, '..', '..')
const BOOTSTRAP = join(REPO, 'ios', 'Resources', 'bootstrap.js')
const STUB_INDEX = join(REPO, 'ios', 'Resources', 'stub-bundle.index.js')
const STUB_CONFIG = join(REPO, 'ios', 'Resources', 'stub-bundle.index.config.js')
const DATA = resolve(REPO, 'host-data', 'p2-stub')
const TIMEOUT = 30000

const TOKEN = randomBytes(16).toString('hex')
let serviceBase = null
let ready = null
const readyPromise = new Promise((res) => (ready = res))

const freePort = () =>
  new Promise((res, rej) => {
    const s = net.createServer()
    s.on('error', rej)
    s.listen(0, '127.0.0.1', () => {
      const port = s.address().port
      s.close(() => res(port))
    })
  })

function startBridge(port) {
  const server = http.createServer((req, res) => {
    if (req.method !== 'POST' || !req.url.startsWith('/msg')) return res.writeHead(404).end()
    if (req.headers['x-catvod-token'] !== TOKEN) return res.writeHead(403).end()
    let body = ''
    req.on('data', (c) => (body += c))
    req.on('end', () => {
      res.writeHead(200, { 'content-type': 'application/json' }).end('{}')
      let msg
      try { msg = JSON.parse(body) } catch { return }
      if (msg.action === 'serverStarted') {
        serviceBase = msg.opt?.address
        console.log(`\n▶ serverStarted  address=${serviceBase}  node=${msg.opt?.version} arch=${msg.opt?.arch} pid=${msg.opt?.pid}`)
        ready(msg.opt || {})
      } else if (msg.action === 'nodeError') {
        console.error(`\n✗ nodeError: ${msg.opt?.message}`)
        ready({ error: msg.opt?.message })
      }
    })
  })
  return new Promise((res, rej) => {
    server.on('error', rej)
    server.listen(port, '127.0.0.1', () => res(server))
  })
}

const get = async (path) => request('GET', path, undefined)

const request = async (method, path, body) => {
  const init = { method, headers: {} }
  if (body !== undefined) {
    init.headers['Content-Type'] = 'application/json'
    init.body = JSON.stringify(body)
  }
  const res = await fetch(serviceBase + path, init)
  return { status: res.status, text: await res.text() }
}

// ---------------------------------------------------------------- 主流程
console.log('=== P2 链路自检（桌面预演，不执行任何下载到的第三方代码）===\n')

// 1) 准备沙箱数据目录（等价 BootstrapLoader）
rmSync(DATA, { recursive: true, force: true })
mkdirSync(DATA, { recursive: true })
const indexFile = join(DATA, 'index.js')
const configFile = join(DATA, 'index.config.js')
for (const f of [BOOTSTRAP, STUB_INDEX, STUB_CONFIG]) {
  if (!existsSync(f)) {
    console.error(`✗ 缺少文件: ${f}`)
    process.exit(2)
  }
}
copyFileSync(STUB_INDEX, indexFile)
copyFileSync(STUB_CONFIG, configFile)
console.log(`✓ 打桩 bundle 已就位: ${DATA}`)

// 2) 起 /msg 桥
const bridgePort = await freePort()
const bridge = await startBridge(bridgePort)
console.log(`✓ bridge 已监听 127.0.0.1:${bridgePort}（token=<redacted len=${TOKEN.length}>）`)

// 3) 用与 iOS 完全相同的 argv 契约启动 bootstrap.js
const args = [BOOTSTRAP, indexFile, configFile, DATA, String(bridgePort), TOKEN]
console.log(`\n即将执行: ${process.execPath} ${args.map((a) => (/\s/.test(a) ? `"${a}"` : a)).join(' ')}\n`)

const child = spawn(process.execPath, args, {
  cwd: DATA,
  stdio: 'inherit',
  env: { ...process.env, CATVOD_DISABLE_AUTOSTART: '1', HOST: '127.0.0.1', PORT: '0', HOME: DATA },
})
child.on('exit', (code, signal) => {
  console.log(`\n[bundle] 进程退出 code=${code} signal=${signal}`)
  if (!serviceBase) ready({ error: `bundle 启动即退出 (code=${code})` })
})

const started = await Promise.race([
  readyPromise,
  new Promise((res) => setTimeout(() => res({ error: `等待 serverStarted 超时（${TIMEOUT}ms）` }), TIMEOUT)),
])

if (started.error) {
  console.error(`\n✗ 启动失败: ${started.error}`)
  child.kill()
  bridge.close()
  process.exit(1)
}

// 4) 客户端侧：把这些请求全部走一遍（与 iOS 自检屏的两个按钮 + P4 的取数路径一致）
// 契约按 M0 实测来（POST + 三段式；GET/两段式应当 404）
const checks = [
  ['GET  /config（站点目录）', 'GET', '/config', undefined, 200],
  ['GET  /config/sites/list', 'GET', '/config/sites/list', undefined, 200],
  ['GET  /versioning', 'GET', '/versioning', undefined, 200],
  ['GET  /health（源自带探活）', 'GET', '/health', undefined, 200],
  ['POST /spider/demo/3/init（站点初始化，必须先调）', 'POST', '/spider/demo/3/init', {}, 200],
  ['POST /spider/demo/3/home（分类+filters）', 'POST', '/spider/demo/3/home', {}, 200],
  ['POST /spider/demo/3/category（列表）', 'POST', '/spider/demo/3/category', { tid: '1', pg: '1' }, 200],
  ['POST /spider/demo/3/detail（详情）', 'POST', '/spider/demo/3/detail', { id: '1' }, 200],
  ['POST /spider/demo/3/search（搜索）', 'POST', '/spider/demo/3/search', { wd: '测试' }, 200],
  ['POST /spider/demo/3/play（取播放地址）', 'POST', '/spider/demo/3/play', { flag: '打桩线路', id: 'stub-episode-2' }, 200],
  ['GET  两段式（应当 404）', 'GET', '/spider/demo/3', undefined, 404],
]

let allOk = true
for (const [label, method, path, body, expect] of checks) {
  try {
    const r = await request(method, path, body)
    const head = r.text.replace(/\s+/g, ' ').slice(0, 130)
    const ok = r.status === expect
    if (!ok) allOk = false
    console.log(`  ${ok ? '✓' : '✗'} ${String(r.status).padEnd(4)} ${label.padEnd(40)} ${head}`)
    if (r.status === 200) writeFileSync(join(DATA, `fixture-${method}${path.replace(/[^\w]+/g, '_')}.txt`), r.text)
  } catch (error) {
    allOk = false
    console.log(`  ✗ ERR  ${label.padEnd(40)} ${error.message}`)
  }
}

// 5) 站点目录可否映射成 TVBox 站点（P4 的 SiteMapper 逻辑，桌面先验一遍）
try {
  const cfg = JSON.parse((await get('/config')).text)
  const sites = (cfg?.video?.sites || []).map((s) => ({ ...s, type: 3, api: `node:/spider/${s.key}/${s.type ?? 3}` }))
  console.log(`\n  站点映射: ${sites.length} 个  ${sites.map((s) => `${s.name}(${s.api})`).join(', ')}`)
  if (!sites.length) allOk = false
} catch (error) {
  allOk = false
  console.log(`\n  ✗ 站点映射失败: ${error.message}`)
}

child.kill()
bridge.close()
console.log(allOk ? '\n✓ P2 链路自检通过' : '\n✗ P2 链路自检失败')
process.exit(allOk ? 0 : 1)
