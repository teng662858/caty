#!/usr/bin/env node
/**
 * node-host.mjs —— 桌面「参考宿主」（第 0 步：把通用接口真正跑起来）
 *
 * 它是 iOS 端要实现的那套东西的桌面等价物：
 *   FongMi NodeBundle   → ensureBundle()      下载 / MD5 校验 / 原子提交 / 缓存复用
 *   FongMi NodeService  → spawnBootstrap()    用真 Node 启动 bootstrap.js 并回收端口
 *   FongMi /msg 桥      → startBridge()       校验 X-CatVod-Token、收 serverStarted/nodeError
 *   FongMi NodeConfigMapper → mapSites()      把本地服务的 /config 翻成 TVBox 站点
 *   FongMi NodeRoute    → nodeRouteAppend()   路由拼接
 *
 * ⚠️ 安全声明：带 --run 时本工具会**执行下载到的第三方 Node 程序**（index.js）。
 *    它拥有完整的文件与网络权限。请只用你信任的源，并建议在独立目录/独立账户下运行。
 *    默认是「干跑」：只下载、校验、准备，不执行任何第三方代码。
 *
 * 用法:
 *   node tools/host/node-host.mjs '<订阅URL>' [--run] [--data DIR] [--fixtures DIR]
 *                                            [--bridge-port N] [--probe-routes] [--timeout MS]
 *
 * 例:
 *   node tools/host/node-host.mjs 'http://user:pass@host/index.js.md5'                       # 干跑
 *   node tools/host/node-host.mjs 'http://user:pass@host/index.js.md5' --run --probe-routes  # 真跑
 */

import { createHash, randomBytes } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import http from 'node:http'
import net from 'node:net'
import { fileURLToPath } from 'node:url'
import { dirname, join, resolve } from 'node:path'
import { spawn } from 'node:child_process'

const HERE = dirname(fileURLToPath(import.meta.url))
const BOOTSTRAP = join(HERE, 'bootstrap.js')

// ------------------------------------------------------------------ CLI
const argv = process.argv.slice(2)
const srcArg = argv.find((a) => !a.startsWith('--'))
if (!srcArg) {
  console.error("用法: node node-host.mjs '<订阅URL>' [--run] [--data DIR] [--fixtures DIR] [--probe-routes]")
  process.exit(2)
}
const has = (f) => argv.includes(`--${f}`)
const opt = (name, def) => {
  const i = argv.indexOf(`--${name}`)
  return i >= 0 && argv[i + 1] ? argv[i + 1] : def
}
const RUN = has('run')
const PROBE_ROUTES = has('probe-routes')
const DATA = resolve(opt('data', 'host-data'))
const FIXTURES = resolve(opt('fixtures', 'fixtures/host'))
const UA = opt('ua', 'okhttp/3.15.0')
const TIMEOUT = Number(opt('timeout', 30000))
const MAX_INDEX_BYTES = 32 * 1024 * 1024
const MAX_CONFIG_BYTES = 2 * 1024 * 1024
const MAX_MD5_BYTES = 1024

const src = new URL(srcArg)
if (!/\/index\.js\.md5$/i.test(src.pathname)) {
  console.error(`! 订阅地址应以 index.js.md5 结尾，实际: ${src.pathname}`)
  process.exit(2)
}
let authHeader = null
if (src.username) {
  authHeader =
    'Basic ' + Buffer.from(`${decodeURIComponent(src.username)}:${decodeURIComponent(src.password)}`).toString('base64')
}
const keyOfSource = srcArg.replace(/^(https?:\/\/)[^@/]*@/, '$1') // 口令不参与目录名
src.username = ''
src.password = ''
const dir = src.origin + src.pathname.replace(/[^/]*$/, '')
const LINKS = {
  md5: src.origin + src.pathname,
  index: dir + 'index.js',
  configMd5: dir + 'index.config.js.md5',
  config: dir + 'index.config.js',
}
const masked = (u) => String(u).replace(/^(https?:\/\/)[^@/]*@/, '$1<user>:***@')

// ---------------------------------------------------------------- 工具函数
const md5buf = (b) => createHash('md5').update(b).digest('hex')
const sha256 = (s) => createHash('sha256').update(s).digest('hex')

async function fetchBuf(url, maxBytes) {
  let current = url
  for (let hop = 0; hop <= 5; hop++) {
    const ctl = new AbortController()
    const timer = setTimeout(() => ctl.abort(), TIMEOUT)
    let res
    try {
      res = await fetch(current, {
        redirect: 'manual',
        headers: { 'User-Agent': UA, Accept: '*/*', ...(authHeader ? { Authorization: authHeader } : {}) },
        signal: ctl.signal,
      })
    } finally {
      clearTimeout(timer)
    }
    if (res.status >= 300 && res.status < 400 && res.headers.get('location')) {
      const next = new URL(res.headers.get('location'), current).toString()
      if (new URL(current).protocol === 'https:' && new URL(next).protocol === 'http:') {
        throw new Error(`拒绝 HTTPS→HTTP 降级跳转: ${masked(next)}`)
      }
      current = next
      continue
    }
    if (!res.ok) throw new Error(`HTTP ${res.status} for ${masked(current)}`)
    const reader = res.body.getReader()
    const chunks = []
    let size = 0
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      size += value.length
      if (size > maxBytes) { await reader.cancel(); throw new Error(`超过上限 ${maxBytes} 字节`) }
      chunks.push(value)
    }
    return Buffer.concat(chunks)
  }
  throw new Error('跳转次数过多')
}

async function remoteMd5(url) {
  const body = await fetchBuf(url, MAX_MD5_BYTES)
  const m = body.toString().match(/(?:^|\s)([a-fA-F0-9]{32})(?:\s|$)/)
  if (!m) throw new Error(`${masked(url)} 里没有 32 位 MD5`)
  return m[1].toLowerCase()
}

// ------------------------------------------------- 1. ensureBundle（缓存与校验）
async function ensureBundle() {
  const root = join(DATA, sha256(keyOfSource))
  const active = join(root, 'active')
  mkdirSync(root, { recursive: true })

  const indexMd5 = await remoteMd5(LINKS.md5)
  let configMd5 = null
  try { configMd5 = await remoteMd5(LINKS.configMd5) } catch { /* 可选 */ }
  console.log(`远程 index.js.md5 = ${indexMd5}${configMd5 ? `  index.config.js.md5 = ${configMd5}` : ''}`)

  // 缓存命中：不重复下载（这正是源站流量与启动速度的关键）
  const marker = join(active, 'index.js.md5')
  const cachedFile = join(active, 'index.js')
  if (existsSync(cachedFile) && existsSync(marker)) {
    const cached = readFileSync(marker, 'utf8').trim().toLowerCase()
    const cachedMd5 = md5buf(readFileSync(cachedFile))
    if (cached === indexMd5 && cachedMd5 === indexMd5) {
      console.log(`✓ 缓存命中（MD5 一致），复用 ${active}`)
      return { root, active, indexMd5, configMd5, indexFile: cachedFile, configFile: join(active, 'index.config.js'), reused: true }
    }
    console.log('· 远程 MD5 变化或缓存损坏 → 重新下载')
  }

  const staging = join(root, `staging-${randomBytes(4).toString('hex')}`)
  mkdirSync(staging, { recursive: true })
  try {
    const indexBody = await fetchBuf(LINKS.index, MAX_INDEX_BYTES)
    const gotIndex = md5buf(indexBody)
    if (gotIndex !== indexMd5) throw new Error(`index.js MD5 不匹配（期望 ${indexMd5}，实得 ${gotIndex}）`)
    writeFileSync(join(staging, 'index.js'), indexBody)
    console.log(`✓ index.js  ${indexBody.length}B  MD5 校验通过`)

    let configOk = false
    if (configMd5) {
      const configBody = await fetchBuf(LINKS.config, MAX_CONFIG_BYTES)
      const gotConfig = md5buf(configBody)
      if (gotConfig !== configMd5) throw new Error(`index.config.js MD5 不匹配`)
      writeFileSync(join(staging, 'index.config.js'), configBody)
      writeFileSync(join(staging, 'index.config.js.md5'), configMd5 + '\n')
      console.log(`✓ index.config.js  ${configBody.length}B  MD5 校验通过`)
      configOk = true
    }
    // 标记文件 + 写入中标记（崩溃恢复依据）
    writeFileSync(join(staging, 'index.js.md5'), indexMd5 + '\n')
    writeFileSync(join(staging, '.pending'), `${indexMd5}:${configMd5 || ''}\n`)

    // 提交（桌面参考实现；iOS 端应做更严格的原子替换）
    if (existsSync(active)) renameSync(active, join(root, `active.old-${Date.now()}`))
    renameSync(staging, active)
    rmSync(join(staging, '.pending'), { force: true })
    for (const f of existsSync(root) ? readdirSync(root) : []) {
      if (f.startsWith('active.old-')) rmSync(join(root, f), { recursive: true, force: true })
    }
    console.log(`✓ 已提交到 ${active}`)
    return {
      root, active, indexMd5, configMd5,
      indexFile: join(active, 'index.js'),
      configFile: join(active, 'index.config.js'),
      reused: false,
      hasConfig: configOk,
    }
  } catch (error) {
    rmSync(staging, { recursive: true, force: true })
    throw error
  }
}

// ----------------------------------------------------------- 2. bridge（/msg 桥）
const TOKEN = randomBytes(16).toString('hex')
let serviceBase = null
let ready = null
const readyPromise = new Promise((res) => (ready = res))

function freePort() {
  return new Promise((res, rej) => {
    const s = net.createServer()
    s.on('error', rej)
    s.listen(0, '127.0.0.1', () => {
      const port = s.address().port
      s.close(() => res(port))
    })
  })
}

function startBridge(port) {
  const server = http.createServer((req, res) => {
    if (req.method !== 'POST' || !req.url.startsWith('/msg')) {
      res.writeHead(404).end()
      return
    }
    if (req.headers['x-catvod-token'] !== TOKEN) {
      res.writeHead(403).end()
      return
    }
    let body = ''
    req.on('data', (c) => {
      body += c
      if (body.length > 1 << 20) req.destroy()
    })
    req.on('end', () => {
      res.writeHead(200, { 'content-type': 'application/json' }).end('{}')
      if (!RUN) return
      let msg
      try { msg = JSON.parse(body) } catch { return }
      if (msg.action === 'serverStarted') {
        serviceBase = msg.opt?.address
        console.log(`\n▶ serverStarted  本地服务地址 = ${serviceBase}`)
        console.log(`  node=${msg.opt?.version} arch=${msg.opt?.arch} pid=${msg.opt?.pid}`)
        ready(msg.opt || {})
      } else if (msg.action === 'nodeError') {
        console.error(`\n✗ nodeError: ${msg.opt?.message}`)
        ready({ error: msg.opt?.message })
      } else {
        console.log(`  [bridge] ${msg.action}`)
      }
    })
  })
  return new Promise((res, rej) => {
    server.on('error', rej)
    server.listen(port, '127.0.0.1', () => res(server))
  })
}

// --------------------------------------------- 3. 客户端侧：/config → TVBox 站点
const isEnabled = (v) => {
  if (v === undefined) return true
  if (typeof v === 'boolean') return v
  if (typeof v === 'number') return v !== 0
  return !(String(v).toLowerCase() === 'false' || String(v) === '0')
}

/** 等价 NodeConfigMapper.route() */
function routeOf(site) {
  let api = typeof site.api === 'string' ? site.api : ''
  if (api) {
    const scheme = api.match(/^[a-z][a-z0-9+.-]*:\/\//i)
    if (scheme) {
      const slash = api.indexOf('/', scheme[0].length)
      api = slash < 0 ? '/' : api.slice(slash)
    }
    return api.startsWith('/') ? api : '/' + api
  }
  let key = typeof site.key === 'string' ? site.key : ''
  if (key.startsWith('nodejs_')) key = key.slice(7)
  if (!key) return ''
  const type = site.type ?? 3
  return `/spider/${key}/${type}`
}

/** 等价 NodeConfigMapper.transform() */
function mapSites(configJson) {
  let root = configJson
  if (root && typeof root === 'object' && root.data && typeof root.data === 'object') root = root.data
  if (!root || typeof root !== 'object' || !root.video || typeof root.video !== 'object') {
    throw new Error('Node /config has no video object')
  }
  const result = { ...root.video }
  const sites = []
  const list = Array.isArray(root.video.sites) ? root.video.sites : []
  for (const site of list) {
    if (!site || typeof site !== 'object') continue
    if (!isEnabled(site.enable)) continue
    const route = routeOf(site)
    if (!route) continue
    sites.push({ ...site, type: 3, api: 'node:' + route })
  }
  result.sites = sites
  return result
}

/** 等价 NodeRoute.append() */
function nodeRouteAppend(api, endpoint) {
  if (!api || !api.startsWith('node:')) throw new Error('Invalid Node API')
  let value = api.slice(5)
  const fragment = value.indexOf('#')
  if (fragment >= 0) value = value.slice(0, fragment)
  const q = value.indexOf('?')
  const suffix = q < 0 ? '' : value.slice(q)
  let path = q < 0 ? value : value.slice(0, q)
  if (!path.startsWith('/')) path = '/' + path
  while (path.endsWith('/') && path.length > 1) path = path.slice(0, -1)
  let child = endpoint == null ? '' : String(endpoint).trim()
  if (child && !child.startsWith('/')) child = '/' + child
  if (path === '/' && child) path = ''
  return 'node:' + path + child + suffix
}

async function getLocal(pathname) {
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), TIMEOUT)
  try {
    const res = await fetch(serviceBase + pathname, { headers: { 'User-Agent': UA }, signal: ctl.signal })
    const text = await res.text()
    return { status: res.status, contentType: res.headers.get('content-type'), text }
  } finally {
    clearTimeout(timer)
  }
}

function saveFixture(name, text) {
  mkdirSync(FIXTURES, { recursive: true })
  const slug = name.replace(/[^a-zA-Z0-9._-]+/g, '_').slice(0, 80) || 'root'
  writeFileSync(join(FIXTURES, `${slug}.txt`), text)
}

// ------------------------------------------------------------------ 主流程
console.log(`\n=== 参考宿主 ===\n订阅: ${masked(srcArg)}`)
if (RUN) {
  console.log('\n⚠️  --run：将执行下载到的第三方 Node 程序。请确认这是你信任的源。\n')
} else {
  console.log('\n（干跑模式：只下载与校验，不执行第三方代码。加 --run 才会真正启动）\n')
}

const bundle = await ensureBundle()
const bridgePort = Number(opt('bridge-port', 0)) || (await freePort())
const bridgeServer = await startBridge(bridgePort)
console.log(`✓ bridge 已监听 127.0.0.1:${bridgePort}  (token 已生成)`)

const spawnArgs = [BOOTSTRAP, bundle.indexFile, bundle.configFile, bundle.active, String(bridgePort), TOKEN]
const nodeBin = process.execPath
console.log(`\n将要执行的命令:`)
console.log(`  ${nodeBin} ${spawnArgs.map((a) => (/\s/.test(a) ? `"${a}"` : a)).join(' ')}`)
console.log(`  cwd=${bundle.active}`)

if (!RUN) {
  console.log('\n干跑结束。确认无误后加 --run 真正启动。')
  bridgeServer.close()
  process.exit(0)
}

// 4. 启动 bundle（等价 NodeService：独立子进程 + 沙箱内路径 + 崩溃即视为失败）
const child = spawn(nodeBin, spawnArgs, {
  cwd: bundle.active,
  stdio: 'inherit',
  windowsHide: true,
  env: {
    ...process.env,
    CATVOD_DISABLE_AUTOSTART: '1',
    HOST: '127.0.0.1',
    PORT: '0',
    HOME: bundle.active,
  },
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
  bridgeServer.close()
  process.exit(1)
}

// 5. 客户端侧：拉站点目录
console.log('\n--- 客户端侧：GET /config ---')
try {
  const cfg = await getLocal('/config')
  console.log(`HTTP ${cfg.status}  type=${cfg.contentType}  ${cfg.text.length}B`)
  saveFixture('res_config', cfg.text)
  let parsed
  try { parsed = JSON.parse(cfg.text) } catch { parsed = null }
  if (parsed) {
    try {
      const mapped = mapSites(parsed)
      console.log(`映射出 ${mapped.sites.length} 个站点（type=3, api=node:<route>）：`)
      for (const s of mapped.sites) {
        console.log(`   · ${JSON.stringify(s.name ?? '')}   api=${s.api}   key=${s.key ?? '-'}`)
      }
      writeFileSync(join(FIXTURES, 'sites.mapped.json'), JSON.stringify(mapped.sites, null, 2))
    } catch (e) {
      console.log(`映射失败: ${e.message}`)
      console.log(`原始顶层键: ${Object.keys(parsed).join(', ')}`)
    }
  } else {
    console.log('（响应不是 JSON，原文已存 fixture）')
  }
} catch (error) {
  console.error(`GET /config 失败: ${error.message}`)
}

for (const p of ['/config/sites/list', '/versioning']) {
  try {
    const r = await getLocal(p)
    console.log(`GET ${p} → ${r.status} ${r.text.length}B`)
    saveFixture(`res${p.replace(/\//g, '_')}`, r.text)
  } catch (error) {
    console.log(`GET ${p} → 失败: ${error.message}`)
  }
}

// 6. 路由探测（M0 的核心产出：确认 endpoint 约定）
if (PROBE_ROUTES) {
  console.log('\n--- 路由探测（用于确认 endpoint 命名，结果存 fixture）---')
  let route = null
  try {
    const mapped = mapSites(JSON.parse(readFileSync(join(FIXTURES, 'res_config.txt'), 'utf8')))
    route = mapped.sites[0]?.api
  } catch { /* 忽略 */ }
  if (!route) {
    console.log('（拿不到站点路由，跳过）')
  } else {
    const candidates = [
      '',
      '?ac=list',
      '?ac=detail&ids=1',
      '?ac=search&wd=%E6%B5%8B%E8%AF%95',
      '/home',
      '/home?ac=list',
      '/search?wd=%E6%B5%8B%E8%AF%95',
      '/detail?ids=1',
      '/homeContent',
      '/category?tid=1&pg=1',
      '/detailContent?ids=1',
      '/searchContent?wd=%E6%B5%8B%E8%AF%95',
      '/playerContent?flag=x&id=1',
    ]
    const base = route.slice(5) // 去掉 node:
    for (const c of candidates) {
      const path = base + c
      try {
        const r = await getLocal(path)
        const head = r.text.replace(/\s+/g, ' ').slice(0, 140)
        console.log(`  ${String(r.status).padEnd(4)} ${path.padEnd(46)} ${head}`)
        if (r.status === 200 && r.text.length > 2) saveFixture(`route${path}`, r.text)
      } catch (error) {
        console.log(`  ERR  ${path.padEnd(46)} ${error.message}`)
      }
    }
  }
}

console.log(`\n服务仍在运行：${serviceBase}`)
console.log(`你可以直接 curl 它，例如:`)
console.log(`  curl -s ${serviceBase}/config | head -c 400`)
console.log(`按 Ctrl+C 结束。\n`)

const shutdown = () => {
  console.log('\n正在停止…')
  try { child.kill() } catch {}
  bridgeServer.close()
  process.exit(0)
}
process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)
