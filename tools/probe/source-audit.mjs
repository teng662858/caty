#!/usr/bin/env node
/**
 * source-audit.mjs —— **源体检**：一个源里的每个站点都过一遍，看谁真能用
 *
 * 对每个站点依次打（和 App 完全一样的顺序）：
 *   POST /spider/<key>/3/init      看它解析出的上游地址（空/超时=这个站点自己有问题）
 *   POST /spider/<key>/3/home      看分类数
 *   POST /spider/<key>/3/category  看第一页条数、以及**有多少条带封面**
 * 最后给一张表 + 汇总：能用 / 返回空 / 报错（附源给的原因）
 *
 * ⚠️ 会执行下载到的第三方 bundle（同 node-host --run）。只对你自己的源跑。
 *
 * 用法:
 *   node tools/probe/source-audit.mjs '<订阅URL>' [--concurrency 4] [--limit 20]
 *                                       [--sites key1,key2] [--timeout 20000] [--quiet]
 * 产物: host-data/audit/<源hash>/report-<yyyyMMdd-HHmm>.json（已 gitignore）
 */

import { createHash, randomBytes } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
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
const has = (k) => opts[k] !== undefined

const sourceUrl = positional[0]
if (!sourceUrl) {
  console.error("用法: node tools/probe/source-audit.mjs '<订阅URL>' [--concurrency 4] [--limit 20]")
  process.exit(2)
}
const CONCURRENCY = Number(opt('concurrency', 4))
const LIMIT = Number(opt('limit', 0)) || Infinity
const ONLY = opt('sites', '').split(',').map((s) => s.trim()).filter(Boolean)
const REQUEST_TIMEOUT = Number(opt('timeout', 25000))
const QUIET = has('quiet')
/** --pic-check N：真的把封面抓一遍（有些站点"有地址但图加载不出来"，那是源/上游的事） */
const PIC_CHECK = Number(opt('pic-check', 0))
const UA = 'okhttp/3.15.0'

// ------------------------------------------------------------------ 下载/缓存 bundle
const parsed = new URL(sourceUrl)
if (!/\/index\.js\.md5$/i.test(parsed.pathname)) {
  console.error('! 订阅地址应以 index.js.md5 结尾')
  process.exit(2)
}
const clean = sourceUrl.replace(/^(https?:\/\/)[^@/]*@/, '$1')
const sourceHash = createHash('sha256').update(clean).digest('hex')
const dataDir = join(ROOT, 'host-data', 'audit', sourceHash)
mkdirSync(dataDir, { recursive: true })

const authHeader = parsed.username
  ? 'Basic ' + Buffer.from(`${decodeURIComponent(parsed.username)}:${decodeURIComponent(parsed.password)}`).toString('base64')
  : null
const base = `${parsed.origin}${parsed.pathname.replace(/[^/]*$/, '')}`

async function fetchText(url, maxBytes = 32 * 1024 * 1024) {
  const response = await fetch(url, { headers: authHeader ? { Authorization: authHeader, 'User-Agent': UA } : { 'User-Agent': UA }, redirect: 'follow' })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  const buffer = Buffer.from(await response.arrayBuffer())
  if (buffer.length > maxBytes) throw new Error(`太大（${buffer.length}B）`)
  return buffer
}

const md5 = (buffer) => createHash('md5').update(buffer).digest('hex')

async function ensureBundle() {
  const remoteMd5 = (await fetchText(base + 'index.js.md5', 4096)).toString('utf8').trim().toLowerCase()
  const indexFile = join(dataDir, 'index.js')
  const configFile = join(dataDir, 'index.config.js')
  if (existsSync(indexFile) && md5(readFileSync(indexFile)) === remoteMd5) {
    console.log(`· 缓存命中 bundle ${remoteMd5.slice(0, 12)}…`)
    return { indexFile, configFile }
  }
  const indexBody = await fetchText(base + 'index.js')
  const got = md5(indexBody)
  if (got !== remoteMd5) throw new Error(`index.js MD5 不符（期望 ${remoteMd5} 实得 ${got}）`)
  writeFileSync(indexFile, indexBody)
  try {
    const configMd5 = (await fetchText(base + 'index.config.js.md5', 4096)).toString('utf8').trim().toLowerCase()
    const configBody = await fetchText(base + 'index.config.js', 4 * 1024 * 1024)
    if (md5(configBody) === configMd5) writeFileSync(configFile, configBody)
  } catch (error) {
    console.warn(`· index.config.js 拉取失败（忽略）：${error.message}`)
  }
  console.log(`✓ bundle 就绪 ${remoteMd5.slice(0, 12)}…（${(indexBody.length / 1048576).toFixed(1)} MB）`)
  return { indexFile, configFile }
}

// ------------------------------------------------------------------ 桥 + 启动
const TOKEN = randomBytes(16).toString('hex')
let serviceBase = null
let readyResolve
const readyPromise = new Promise((r) => (readyResolve = r))

const freePort = () => new Promise((res, rej) => {
  const s = net.createServer()
  s.on('error', rej)
  s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => res(p)) })
})

const bridgePort = await freePort()
const bridge = http.createServer((req, res) => {
  if (req.method !== 'POST' || !req.url.startsWith('/msg')) return res.writeHead(404).end()
  if (req.headers['x-catvod-token'] !== TOKEN) return res.writeHead(403).end()
  let body = ''
  req.on('data', (c) => { body += c })
  req.on('end', () => {
    res.writeHead(200, { 'content-type': 'application/json' }).end('{}')
    let msg
    try { msg = JSON.parse(body) } catch { return }
    if (msg.action === 'sourceStarted' || msg.action === 'serverStarted') {
      if (!serviceBase) {
        serviceBase = msg.opt?.address
        readyResolve(msg.opt || {})
      }
    }
  })
})
await new Promise((r) => bridge.listen(bridgePort, '127.0.0.1', r))

const { indexFile, configFile } = await ensureBundle()
const specPath = join(dataDir, 'audit-spec.json')
writeFileSync(specPath, JSON.stringify({
  bridgePort,
  token: TOKEN,
  sources: [{ id: 'audit', index: indexFile, config: configFile, dataRoot: dataDir }],
}, null, 2))

const child = spawn(process.execPath, [BOOTSTRAP, specPath], { stdio: ['ignore', 'pipe', 'pipe'] })
const sourceLog = []
for (const stream of [child.stdout, child.stderr]) {
  stream.on('data', (c) => {
    for (const line of String(c).split('\n')) {
      const trimmed = line.trim()
      if (!trimmed) continue
      sourceLog.push(trimmed)
      if (!QUIET && /bootstrap|FastSiteUrl|出错|失败|error/i.test(trimmed)) console.log(`  [源] ${trimmed.slice(0, 200)}`)
    }
  })
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
let started = false
for (let i = 0; i < 300 && !started; i++) {
  if (serviceBase) { started = true; break }
  await sleep(200)
}
if (!serviceBase) {
  console.error('✗ 源没能启动（看下面的 [源] 日志）')
  child.kill(); bridge.close(); process.exit(1)
}
console.log(`▶ 源已就绪 ${serviceBase}\n`)

async function callAbsolute(url) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT)
  try {
    const response = await fetch(url, { headers: { 'User-Agent': UA, Referer: base }, signal: controller.signal })
    const buffer = Buffer.from(await response.arrayBuffer())
    return { status: response.status, bytes: buffer.length, text: 'binary ' + buffer.length + 'B ' + (response.headers.get('content-type') || '') }
  } catch (error) {
    return { status: -1, bytes: 0, text: error.name === 'AbortError' ? '超时' : error.message }
  } finally {
    clearTimeout(timer)
  }
}

async function call(method, path, body) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT)
  const started = Date.now()
  try {
    const headers = { 'User-Agent': UA }
    const init = { method, headers, signal: controller.signal }
    if (body !== undefined) {
      headers['Content-Type'] = 'application/json'
      init.body = JSON.stringify(body)
    }
    const response = await fetch(serviceBase + path, init)
    const text = await response.text()
    let json = null
    try { json = JSON.parse(text) } catch { /* 非 JSON */ }
    return { status: response.status, ms: Date.now() - started, json, text }
  } catch (error) {
    return { status: -1, ms: Date.now() - started, json: null, text: error.name === 'AbortError' ? '超时' : error.message }
  } finally {
    clearTimeout(timer)
  }
}

// ------------------------------------------------------------------ 体检
const config = await call('GET', '/config')
const sites = (config.json?.video?.sites || []).map((s) => ({
  key: String(s.key).replace(/^nodejs_/, ''),
  name: s.name,
  api: String(s.api || `/spider/${String(s.key).replace(/^nodejs_/, '')}/3`),
  searchable: Number(s.searchable ?? 1) === 1,
})).filter((s) => !ONLY.length || ONLY.includes(s.key))

console.log(`共 ${sites.length} 个站点开始体检（并发 ${CONCURRENCY}，单请求超时 ${REQUEST_TIMEOUT}ms）\n`)

const results = []
let done = 0

async function auditSite(site) {
  const row = { key: site.key, name: site.name, upstream: null, init: null, home: null, category: null, items: 0, withPic: 0, verdict: '?', message: '' }
  const init = await call('POST', `${site.api}/init`, {})
  row.init = init.status
  row.upstream = init.json?.siteUrl ?? init.json?.url ?? null
  if (init.status !== 200 && init.status !== 404) {
    row.message = init.json?.message ?? init.text.slice(0, 120)
  }

  const home = await call('POST', `${site.api}/home`, {})
  row.home = home.status
  const classes = home.json?.class || []
  if (home.status !== 200) {
    row.message = row.message || (home.json?.message ?? home.text.slice(0, 120))
    row.verdict = '报错'
    return row
  }

  const tid = classes[0]?.type_id
  if (!tid) {
    row.verdict = classes.length ? '无分类' : '空'
    return row
  }
  const cat = await call('POST', `${site.api}/category`, { tid, pg: '1' })
  row.category = cat.status
  const list = cat.json?.list || []
  row.items = list.length
  row.withPic = list.filter((x) => x.vod_pic && String(x.vod_pic).trim()).length

  // 可选：真的抓几张封面（走源自己的 imageProxy），看是不是"有地址但加载不出来"
  if (PIC_CHECK > 0 && list.length) {
    row.pics = []
    for (const item of list.slice(0, PIC_CHECK)) {
      const pic = item.vod_pic ? String(item.vod_pic).trim() : ''
      if (!pic) {
        row.pics.push({ name: item.vod_name, status: 0, note: '无地址' })
        continue
      }
      // 源自己的本地代理（/imageProxy…）走本地服务；外链图片直接抓
      const picked = pic.startsWith(serviceBase)
        ? await call('GET', pic.slice(serviceBase.length))
        : await callAbsolute(pic)
      row.pics.push({
        name: item.vod_name,
        status: picked.status,
        bytes: picked.text ? picked.text.length : 0,
        note: picked.status === 200 ? 'ok' : picked.text.slice(0, 40),
      })
    }
    row.picFail = row.pics.filter((x) => x.status !== 200).length
    if (row.picFail) {
      row.message = (row.message ? row.message + '；' : '') + '封面 ' + row.picFail + '/' + row.pics.length + ' 张抓不到'
    }
  }
  if (cat.status !== 200) {
    row.message = row.message || (cat.json?.message ?? cat.text.slice(0, 120))
    row.verdict = '报错'
  } else if (list.length === 0) {
    row.verdict = '空'
  } else {
    row.verdict = '可用'
  }
  return row
}

let cursor = 0
async function worker() {
  while (cursor < sites.length && cursor < LIMIT) {
    const site = sites[cursor++]
    try {
      const row = await auditSite(site)
      results.push(row)
    } catch (error) {
      results.push({ key: site.key, name: site.name, verdict: '异常', message: error.message })
    }
    done++
    if (done % 10 === 0 || done === sites.length) console.log(`  …${done}/${Math.min(sites.length, LIMIT)}`)
  }
}

await Promise.all(Array.from({ length: Math.min(CONCURRENCY, sites.length) }, worker))

// ------------------------------------------------------------------ 报告
results.sort((a, b) => sites.findIndex((s) => s.key === a.key) - sites.findIndex((s) => s.key === b.key))
const usable = results.filter((r) => r.verdict === '可用')
const empty = results.filter((r) => r.verdict === '空' || r.verdict === '无分类')
const broken = results.filter((r) => r.verdict === '报错' || r.verdict === '异常')

console.log('\n=== 体检结果 ===')
for (const row of results) {
  const pic = row.items ? (row.withPic + '/' + row.items + ' 有封面' + (row.picFail ? '（' + row.picFail + ' 张抓不到）' : '')) : '-'
  const up = row.upstream ? String(row.upstream).replace(/^https?:\/\//, '').slice(0, 28) : '-'
  console.log(`  ${row.verdict === '可用' ? '✓' : row.verdict === '空' ? '·' : '✗'} ${String(row.name).slice(0, 14).padEnd(16)} ${String(row.verdict).padEnd(4)} init=${String(row.init).padEnd(4)} home=${String(row.home).padEnd(4)} cat=${String(row.category).padEnd(4)} 条=${String(row.items).padEnd(4)} ${pic.padEnd(12)} 上游=${up}${row.message ? `  ${String(row.message).slice(0, 60)}` : ''}`)
}

const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 13)
const report = { source: clean, auditedAt: new Date().toISOString(), total: results.length, usable: usable.length, empty: empty.length, broken: broken.length, results }
const reportPath = join(dataDir, `report-${stamp}.json`)
writeFileSync(reportPath, JSON.stringify(report, null, 2))

console.log(`\n汇总：可用 ${usable.length} / 空返回 ${empty.length} / 报错 ${broken.length}（共 ${results.length}）`)
if (broken.length) {
  console.log('报错的站点：' + broken.map((r) => r.name).slice(0, 20).join('、'))
}
console.log(`报告已存：${reportPath}`)

child.kill()
bridge.close()
await sleep(300)
process.exit(0)
