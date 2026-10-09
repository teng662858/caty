#!/usr/bin/env node
/**
 * site-probe.mjs —— 单站点探测：把"某个站点打不开"这件事在桌面上复现出来
 *
 * 它复用节点缓存里**已经下载好的** bundle（不再联网下载），用 tools/host/bootstrap.js
 * 启动真源，然后对指定站点逐个打 home / category / detail / search / play，
 * 把 **HTTP 状态、耗时、响应体、源自己打印的日志** 全部原样打出来。
 *
 * ⚠️ 它会**执行第三方 Node 程序**（缓存里的 index.js），和 node-host.mjs --run 一样。
 *    只对你自己信任的源跑；本工具不带下载，跑的是你上次已经下载并校验过的那份。
 *
 * 用法:
 *   node tools/probe/site-probe.mjs [bundle目录] [--sites huban,wogg] [--wd 关键词]
 *                                   [--ops home,category,detail] [--timeout MS] [--full]
 *
 * 例:
 *   # 不指定目录：自动取 host-data 里最近一次下载（含 index.js）的那份
 *   node tools/probe/site-probe.mjs --sites huban,wogg,duoduo
 *   node tools/probe/site-probe.mjs host-data/74f69ac.../active --sites huban --full
 */

import { randomBytes } from 'node:crypto'
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import http from 'node:http'
import net from 'node:net'
import { spawn } from 'node:child_process'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '..', '..')
const BOOTSTRAP = join(ROOT, 'tools', 'host', 'bootstrap.js')

const argv = process.argv.slice(2)
const opts = {}
const positional = []
for (let i = 0; i < argv.length; i++) {
  const a = argv[i]
  if (!a.startsWith('--')) { positional.push(a); continue }
  const name = a.slice(2)
  const next = argv[i + 1]
  if (next !== undefined && !next.startsWith('--')) { opts[name] = next; i++ } else { opts[name] = true }
}
const has = (f) => opts[f] !== undefined
const opt = (name, def) => (opts[name] === undefined || opts[name] === true ? def : String(opts[name]))
const bundleArg = positional[0]
const WANT = (opt('sites', 'huban')).split(',').map((s) => s.trim()).filter(Boolean)
const KEYWORD = opt('wd', '庆余年')
const OPS = (opt('ops', 'init,home,category,detail,search')).split(',').map((s) => s.trim()).filter(Boolean)
const PATHS = opt('paths', '').split(',').map((s) => s.trim()).filter(Boolean)
const TIMEOUT = Number(opt('timeout', 60000))
const FULL = has('full')
const UA = opt('ua', 'okhttp/3.15.0')

// ------------------------------------------------------------------ 找 bundle
function findBundle() {
  if (bundleArg) {
    const dir = resolve(bundleArg)
    if (existsSync(join(dir, 'index.js'))) return dir
    console.error(`! ${dir} 里没有 index.js`)
    process.exit(2)
  }
  const dataDir = resolve(ROOT, 'host-data')
  const candidates = []
  for (const name of readdirSync(dataDir)) {
    for (const sub of ['active', '']) {
      const dir = join(dataDir, name, sub)
      const index = join(dir, 'index.js')
      if (existsSync(index)) candidates.push({ dir, mtime: statSync(index).mtimeMs, size: statSync(index).size })
    }
  }
  if (!candidates.length) {
    console.error('! host-data 里没有缓存 bundle，先用 node-host.mjs 下载一份（干跑即可）')
    process.exit(2)
  }
  // 真源是 6–10 MB 的 esbuild 产物；打桩 bundle 只有几 KB → 优先挑最大的那份
  candidates.sort((a, b) => (b.size - a.size) || (b.mtime - a.mtime))
  return candidates[0].dir
}

const BUNDLE = findBundle()
const INDEX_FILE = join(BUNDLE, 'index.js')
const CONFIG_FILE = join(BUNDLE, 'index.config.js')

// ------------------------------------------------------------------ 桥 + 启动
const TOKEN = randomBytes(16).toString('hex')
let serviceBase = null
let readyResolve
const readyPromise = new Promise((res) => (readyResolve = res))

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

const bridgeMessages = []
function startBridge(port) {
  const server = http.createServer((req, res) => {
    if (req.method !== 'POST' || !req.url.startsWith('/msg')) return res.writeHead(404).end()
    if (req.headers['x-catvod-token'] !== TOKEN) return res.writeHead(403).end()
    let body = ''
    req.on('data', (c) => {
      body += c
      if (body.length > (1 << 22)) req.destroy()
    })
    req.on('end', () => {
      res.writeHead(200, { 'content-type': 'application/json' }).end('{}')
      let msg
      try { msg = JSON.parse(body) } catch { return }
      if (msg.action === 'serverStarted') {
        serviceBase = msg.opt?.address
        console.log(`\n▶ serverStarted  ${serviceBase}  node=${msg.opt?.version} pid=${msg.opt?.pid}`)
        readyResolve(msg.opt || {})
      } else if (msg.action === 'nodeError') {
        console.error(`\n✗ nodeError: ${msg.opt?.message}`)
        readyResolve({ error: msg.opt?.message })
      } else {
        const text = JSON.stringify(msg).slice(0, 300)
        bridgeMessages.push(text)
        console.log(`  [桥] ${text}`)
      }
    })
  })
  return new Promise((res, rej) => {
    server.on('error', rej)
    server.listen(port, '127.0.0.1', () => res(server))
  })
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function local(method, path, body, timeout = TIMEOUT) {
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), timeout)
  const started = Date.now()
  try {
    const headers = { 'User-Agent': UA }
    const init = { method, headers, signal: ctl.signal }
    if (body !== undefined) {
      headers['Content-Type'] = 'application/json'
      init.body = JSON.stringify(body)
    }
    const res = await fetch(serviceBase + path, init)
    const text = await res.text()
    let json = null
    try { json = JSON.parse(text) } catch { /* 非 JSON */ }
    return { status: res.status, ms: Date.now() - started, text, json }
  } catch (error) {
    return { status: -1, ms: Date.now() - started, text: `ERR ${error.name}: ${error.message}`, json: null }
  } finally {
    clearTimeout(timer)
  }
}

const short = (text, n = 220) => String(text ?? '').replace(/\s+/g, ' ').slice(0, n)

function report(label, r, { full = FULL } = {}) {
  const ok = r.status === 200
  console.log(`    ${ok ? '✓' : '✗'} ${String(r.status).padEnd(4)} ${String(r.ms + 'ms').padEnd(7)} ${label}`)
  if (r.status !== 200 || full) console.log(`        ${short(r.text, r.status === 200 ? 400 : 900)}`)
  return r
}

// ------------------------------------------------------------------ 主流程
const bridgePort = await freePort()
await startBridge(bridgePort)

console.log(`=== 单站点探测 ===\nbundle: ${BUNDLE}`)
console.log(`探测站点: ${WANT.join(', ')}   操作: ${OPS.join(', ')}   关键词: ${KEYWORD}\n`)

const child = spawn(process.execPath, [BOOTSTRAP, INDEX_FILE, CONFIG_FILE, BUNDLE, String(bridgePort), TOKEN], {
  cwd: BUNDLE,
  stdio: ['ignore', 'pipe', 'pipe'],
  env: { ...process.env, CATVOD_DISABLE_AUTOSTART: '1' },
})
child.stdout.on('data', (c) => {
  for (const line of String(c).split('\n')) {
    if (line.trim()) console.log(`  [源] ${line.trim().slice(0, 400)}`)
  }
})
child.stderr.on('data', (c) => {
  for (const line of String(c).split('\n')) {
    if (line.trim()) console.log(`  [源!] ${line.trim().slice(0, 400)}`)
  }
})

const started = Date.now()
const startup = await Promise.race([readyPromise, sleep(TIMEOUT).then(() => ({ error: '启动超时' }))])
if (startup.error) {
  console.error(`\n✗ 启动失败/超时：${startup.error}`)
  child.kill()
  process.exit(1)
}
console.log(`  启动耗时 ${((Date.now() - started) / 1000).toFixed(2)}s\n`)

// --- /config
const cfg = await local('GET', '/config')
if (cfg.status !== 200 || !cfg.json?.video?.sites) {
  console.error(`✗ GET /config → ${cfg.status}  ${short(cfg.text)}`)
  child.kill()
  process.exit(1)
}
const sites = cfg.json.video.sites

// --- 额外的诊断端点（例如 /website/api/remote-wex、/website/api/db）
for (const p of PATHS) {
  const r = await local('GET', p)
  console.log(`\n--- GET ${p} → ${r.status}  ${r.ms}ms  ${r.text.length}B`)
  console.log(`    ${r.text.replace(/\s+/g, ' ').slice(0, 2000)}\n`)
}

const picked = []
for (const want of WANT) {
  const hit = sites.find((s) => String(s.key).replace(/^nodejs_/, '') === want) ||
    sites.find((s) => String(s.name).includes(want)) ||
    sites.find((s) => String(s.key).includes(want))
  if (hit) picked.push(hit)
  else console.log(`  ! /config 里找不到站点「${want}」`)
}
console.log(`  /config 共 ${sites.length} 个站点，命中 ${picked.length} 个\n`)

const summary = []
for (const site of picked) {
  const key = String(site.key).replace(/^nodejs_/, '')
  const base = site.api && String(site.api).startsWith('/') ? site.api : `/spider/${key}/3`
  console.log(`▸ ${site.name}  key=${key}  api=${base}  searchable=${site.searchable}`)
  const row = { site: `${site.name}`, init: '-', home: '-', category: '-', detail: '-', search: '-' }

  let tids = []
  let filters = null
  let firstVodId = null
  let detailJson = null

  if (OPS.includes('init')) {
    // 宿主必须先调 init，站点才会解析自己真正的上游域名（见 docs/contract-notes.md §8）
    const r = report(`POST ${base}/init`, await local('POST', `${base}/init`, {}))
    row.init = `${r.status} ${r.ms}ms`
    if (r.json?.siteUrl) console.log(`        上游地址 = ${r.json.siteUrl}`)
  }

  if (OPS.includes('home')) {
    const r = report(`POST ${base}/home`, await local('POST', `${base}/home`, {}))
    row.home = `${r.status} ${r.ms}ms`
    tids = (r.json?.class || []).map((c) => c.type_id).filter(Boolean)
    filters = r.json?.filters || null
    console.log(`        分类 ${tids.length} 个${tids.length ? `: ${(r.json.class || []).map((c) => c.type_name).slice(0, 8).join('/')}` : ''}${filters ? '  含 filters' : ''}`)
  }

  if (OPS.includes('category') && tids.length) {
    const r = report(`POST ${base}/category {tid:"${tids[0]}",pg:"1"}`,
      await local('POST', `${base}/category`, { tid: tids[0], pg: '1' }))
    row.category = `${r.status} ${r.ms}ms`
    const list = r.json?.list || []
    console.log(`        列表 ${list.length} 条${list[0] ? `，首条《${list[0].vod_name}》` : ''}  page=${r.json?.page} pagecount=${r.json?.pagecount}`)
    firstVodId = list[0]?.vod_id ?? null

    // 带筛选项再打一次（有的站点缺 extend 会报错）
    if (filters && filters[tids[0]]) {
      const ext = {}
      for (const g of filters[tids[0]]) {
        const v = g.value?.[0]?.v ?? g.value?.[0]?.value
        if (g.key && v !== undefined) ext[g.key] = v
      }
      if (Object.keys(ext).length) {
        const r2 = report(`POST ${base}/category {tid,pg,filter:"1",extend:${JSON.stringify(ext)}}`,
          await local('POST', `${base}/category`, { tid: tids[0], pg: '1', filter: '1', extend: ext }))
        console.log(`        （带筛选）列表 ${(r2.json?.list || []).length} 条`)
      }
    }
  }

  if (OPS.includes('detail') && firstVodId) {
    const r = report(`POST ${base}/detail {id:"${String(firstVodId).slice(0, 40)}"}`,
      await local('POST', `${base}/detail`, { id: firstVodId }))
    row.detail = `${r.status} ${r.ms}ms`
    detailJson = r.json
    const item = r.json?.list?.[0]
    if (item) {
      console.log(`        《${item.vod_name}》线路=${short(item.vod_play_from, 60)}`)
      console.log(`        剧集串=${short(item.vod_play_url, 120)}`)
    }
  }

  if (OPS.includes('search')) {
    const r = report(`POST ${base}/search {wd:"${KEYWORD}"}`,
      await local('POST', `${base}/search`, { wd: KEYWORD }))
    row.search = `${r.status} ${r.ms}ms`
    console.log(`        结果 ${(r.json?.list || []).length} 条`)
  }

  // 播放：只做"取到地址"这一步，不下载
  if (OPS.includes('play') && detailJson) {
    const item = detailJson.list?.[0]
    const flag = String(item?.vod_play_from || '').split('$$$')[0]
    const entry = String(item?.vod_play_url || '').split('$$$')[0]?.split('#')[0] || ''
    const id = entry.includes('$') ? entry.split('$').slice(1).join('$') : entry
    if (flag && id) {
      report(`POST ${base}/play {flag:"${flag}",id:"${String(id).slice(0, 30)}…"}`,
        await local('POST', `${base}/play`, { flag, id }))
    }
  }
  console.log('')
  summary.push(row)
}

console.log('\n=== 汇总 ===')
for (const row of summary) {
  console.log(`  ${row.site.padEnd(16)} init ${String(row.init).padEnd(11)} home ${String(row.home).padEnd(12)} category ${String(row.category).padEnd(12)} detail ${String(row.detail).padEnd(12)} search ${row.search}`)
}
if (bridgeMessages.length) {
  console.log('\n源通过桥推的消息：')
  for (const m of bridgeMessages.slice(0, 20)) console.log(`  ${m}`)
}

child.kill()
await sleep(300)
process.exit(0)
