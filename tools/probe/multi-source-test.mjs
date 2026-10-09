#!/usr/bin/env node
/**
 * multi-source-test.mjs —— 验证「一个 Node 进程跑多个源」+「运行期追加源」（桌面）
 *
 * 这是 App 侧「不用重启就能切换源」那条路的桌面等价测试：
 *   1. 写一个 spec.json（两个缓存里的源）→ node bootstrap.js spec.json
 *   2. 等两个 sourceStarted → 分别 GET /config，看站点数
 *   3. 挑一个站点走 init → home，确认内容真的取得到（证明多源之间没有串台）
 *   4. 用控制口 POST /ctl/source **在运行期再追加一个源**，确认它也能起来
 *   5. GET /ctl/status 看总账；最后全部关掉
 *
 * ⚠️ 会执行缓存里的第三方 bundle（和 site-probe / node-host --run 一样）。
 *
 * 用法:
 *   node tools/probe/multi-source-test.mjs [bundle目录A] [bundle目录B] [--site huban] [--runtime-add]
 */

import { randomBytes } from 'node:crypto'
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import http from 'node:http'
import net from 'node:net'
import { spawn } from 'node:child_process'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '..', '..')
const BOOTSTRAP = join(ROOT, 'tools', 'host', 'bootstrap.js')

const argv = process.argv.slice(2)
const positional = []
const opts = {}
for (let i = 0; i < argv.length; i++) {
  const a = argv[i]
  if (!a.startsWith('--')) { positional.push(a); continue }
  const name = a.slice(2)
  const next = argv[i + 1]
  if (next !== undefined && !next.startsWith('--')) { opts[name] = next; i++ } else { opts[name] = true }
}
const opt = (k, d) => (opts[k] === undefined || opts[k] === true ? d : String(opts[k]))

/** 找缓存里的 bundle：按 index.js 体积从大到小（真源 6–10 MB，打桩几千字节） */
function cachedBundles() {
  const dataDir = resolve(ROOT, 'host-data')
  const found = []
  for (const name of readdirSync(dataDir)) {
    const index = join(dataDir, name, 'active', 'index.js')
    if (existsSync(index)) found.push({ dir: join(dataDir, name, 'active'), size: statSync(index).size })
  }
  found.sort((a, b) => b.size - a.size)
  return found
}

const freePort = () =>
  new Promise((res, rej) => {
    const s = net.createServer()
    s.on('error', rej)
    s.listen(0, '127.0.0.1', () => {
      const port = s.address().port
      s.close(() => res(port))
    })
  })

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const picks = positional.length
  ? positional.map((p) => ({ dir: resolve(ROOT, p) }))
  : cachedBundles().slice(0, 2)
if (picks.length < 2) {
  console.error('! 至少需要两个 bundle 目录（host-data 里缓存不够）')
  process.exit(2)
}

const TOKEN = randomBytes(16).toString('hex')
const bridgePort = await freePort()

let serviceBySource = new Map()
let controlBase = null
const messages = []

const bridge = http.createServer((req, res) => {
  if (req.method !== 'POST' || !req.url.startsWith('/msg')) return res.writeHead(404).end()
  if (req.headers['x-catvod-token'] !== TOKEN) return res.writeHead(403).end()
  let body = ''
  req.on('data', (c) => { body += c })
  req.on('end', () => {
    res.writeHead(200, { 'content-type': 'application/json' }).end('{}')
    let msg
    try { msg = JSON.parse(body) } catch { return }
    messages.push(msg)
    if (msg.action === 'sourceStarted') {
      serviceBySource.set(msg.opt.id, msg.opt.address)
      console.log(`  [桥] sourceStarted ${msg.opt.id} → ${msg.opt.address}`)
    } else if (msg.action === 'serverStarted') {
      // 兼容性回报，忽略（多源模式下以 sourceStarted 为准）
    } else if (msg.action === 'controlReady') {
      controlBase = msg.opt.address
      console.log(`  [桥] controlReady → ${msg.opt.address}`)
    } else {
      console.log(`  [桥] ${msg.action}: ${JSON.stringify(msg.opt ?? {}).slice(0, 200)}`)
    }
  })
})
await new Promise((r) => bridge.listen(bridgePort, '127.0.0.1', r))

const specPath = join(ROOT, 'host-data', 'multi-spec.json')
const spec = {
  bridgePort,
  token: TOKEN,
  sources: picks.map((p, index) => ({
    id: `src${index + 1}`,
    index: join(p.dir, 'index.js'),
    config: join(p.dir, 'index.config.js'),
    dataRoot: p.dir,
  })),
}
writeFileSync(specPath, JSON.stringify(spec, null, 2))

console.log('=== 多源桌面测试 ===')
for (const s of spec.sources) console.log(`  源 ${s.id}: ${s.dataRoot}`)
console.log(`  spec: ${specPath}\n`)

const child = spawn(process.execPath, [BOOTSTRAP, specPath], { stdio: ['ignore', 'pipe', 'pipe'] })
child.stdout.on('data', (c) => {
  for (const line of String(c).split('\n')) if (line.trim()) console.log(`  [源] ${line.trim().slice(0, 300)}`)
})
child.stderr.on('data', (c) => {
  for (const line of String(c).split('\n')) if (line.trim()) console.log(`  [源!] ${line.trim().slice(0, 300)}`)
})

async function waitFor(check, timeoutMs, label) {
  const started = Date.now()
  while (Date.now() - started < timeoutMs) {
    if (check()) return true
    await sleep(200)
  }
  console.warn(`  ! 等待超时：${label}`)
  return false
}

await waitFor(() => serviceBySource.size >= spec.sources.length && controlBase, 120000, '两个源 + 控制口')

async function local(base, method, path, body, timeoutMs = 30000) {
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), timeoutMs)
  const started = Date.now()
  try {
    const headers = { 'User-Agent': 'okhttp/3.15.0', 'X-CatVod-Token': TOKEN }
    const init = { method, headers, signal: ctl.signal }
    if (body !== undefined) {
      headers['Content-Type'] = 'application/json'
      init.body = JSON.stringify(body)
    }
    const res = await fetch(base + path, init)
    const text = await res.text()
    let json = null
    try { json = JSON.parse(text) } catch { /* 非 JSON */ }
    return { status: res.status, ms: Date.now() - started, text, json }
  } catch (error) {
    return { status: -1, ms: Date.now() - started, text: `ERR ${error.message}`, json: null }
  } finally {
    clearTimeout(timer)
  }
}

const summary = []
for (const source of spec.sources) {
  const base = serviceBySource.get(source.id)
  console.log(`\n▸ 源 ${source.id}  ${base}`)
  const cfg = await local(base, 'GET', '/config')
  const sites = cfg.json?.video?.sites || []
  console.log(`    GET /config → ${cfg.status}  ${sites.length} 个站点  ${cfg.ms}ms`)
  summary.push(`  ${source.id.padEnd(6)} /config ${cfg.status}  ${sites.length} 个站点  ${base}`)
}

// 用一个真站点验证"多源之间不串台"：init → home
const wantKey = opt('site', 'huban')
let target = null
for (const source of spec.sources) {
  const base = serviceBySource.get(source.id)
  const cfg = await local(base, 'GET', '/config')
  const hit = (cfg.json?.video?.sites || []).find((s) => String(s.key).replace(/^nodejs_/, '') === wantKey)
  if (hit) { target = { source, base, hit }; break }
}
if (target) {
  console.log(`\n▸ 跨源取内容：${target.hit.name}（在 ${target.source.id} 上）`)
  const init = await local(target.base, 'POST', `${target.hit.api}/init`, {})
  console.log(`    init → ${init.status} ${init.ms}ms ${init.json?.siteUrl ? `上游 ${init.json.siteUrl}` : ''}`)
  const home = await local(target.base, 'POST', `${target.hit.api}/home`, {})
  const classes = home.json?.class || []
  console.log(`    home → ${home.status} ${home.ms}ms  分类 ${classes.length} 个`)
  summary.push(`  ${target.source.id.padEnd(6)} ${wantKey} init ${init.status} / home ${home.status}（${classes.length} 个分类）`)
}

// 运行期追加一个源（这就是"不用重启 App 换源"的关键路径）
if (opts['runtime-add'] !== false && controlBase) {
  const extraDir = picks[0].dir
  console.log(`\n▸ 运行期追加源（控制口 ${controlBase}）`)
  const added = await local(controlBase, 'POST', '/ctl/source', {
    id: 'late-added',
    index: join(extraDir, 'index.js'),
    config: join(extraDir, 'index.config.js'),
    dataRoot: extraDir,
  }, 90000)
  console.log(`    POST /ctl/source → ${added.status} ${added.ms}ms  ${JSON.stringify(added.json)}`)
  const status = await local(controlBase, 'GET', '/ctl/status')
  const list = status.json?.sources || []
  console.log(`    GET /ctl/status → ${status.status}  在跑 ${list.filter((s) => s.listening).length} 个：${list.map((s) => s.id).join(', ')}`)
  summary.push(`  运行期追加源：${added.status === 200 ? '成功' : '失败'}（${added.json?.address || added.text.slice(0, 60)}）`)
}

console.log('\n=== 汇总 ===')
for (const line of summary) console.log(line)

child.kill()
bridge.close()
await sleep(300)
process.exit(0)
