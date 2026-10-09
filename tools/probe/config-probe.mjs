#!/usr/bin/env node
/**
 * config-probe.mjs —— 「通用接口」(index.js.md5) 静态体检工具
 *
 * 安全声明：本工具**不会执行**任何下载到的 JS。它只做四件事：
 *   下载 → 校验 MD5 → 静态提取配置对象（自写解析器，不 eval / 不 new Function）→ 输出报告
 *
 * 用法:
 *   node tools/probe/config-probe.mjs '<订阅URL>' [--out fixtures/xxx] [--ua '...'] [--timeout 30000]
 *
 * 例:
 *   node tools/probe/config-probe.mjs 'http://user:pass@cat.example.top/index.js.md5' --out fixtures/mysrc
 *
 * 产出（--out 目录下）:
 *   index.js / index.js.md5 / index.config.js / index.config.js.md5   原始文件
 *   sites.catalog.json   从配置里静态提取出来的站点目录（脱敏）
 *   report.json          完整体检报告
 */

import { createHash } from 'node:crypto'
import { mkdirSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

// ---------------------------------------------------------------- CLI

const argv = process.argv.slice(2)
const srcArg = argv.find((a) => !a.startsWith('--'))
if (!srcArg) {
  console.error('用法: node config-probe.mjs <订阅URL(以 index.js.md5 结尾)> [--out DIR] [--ua UA] [--timeout MS]')
  process.exit(2)
}
const opt = (name, def) => {
  const i = argv.indexOf(`--${name}`)
  return i >= 0 && argv[i + 1] ? argv[i + 1] : def
}
const OUT = resolve(opt('out', 'probe-out'))
const UA = opt('ua', 'okhttp/3.15.0')
const TIMEOUT = Number(opt('timeout', 30000))
const MAX_INDEX_BYTES = 32 * 1024 * 1024
const MAX_CONFIG_BYTES = 2 * 1024 * 1024
const MAX_MD5_BYTES = 1024

// ------------------------------------------------------- URL 解析

const src = new URL(srcArg)
if (!/\/index\.js\.md5$/i.test(src.pathname) && src.pathname.toLowerCase() !== '/index.js.md5') {
  console.error(`! 订阅地址应以 index.js.md5 结尾，实际: ${src.pathname}`)
  process.exit(2)
}
// Basic Auth：现代 HTTP 客户端拒绝带凭据的 URL，必须拆出来
let authHeader = null
let userinfo = ''
if (src.username) {
  const u = decodeURIComponent(src.username)
  const p = decodeURIComponent(src.password)
  authHeader = 'Basic ' + Buffer.from(`${u}:${p}`).toString('base64')
  userinfo = `${u}:***@`
}
src.username = ''
src.password = ''
const dir = src.origin + src.pathname.replace(/[^/]*$/, '') // 目录（含末尾 /）
const origin = src.origin
const URLS = {
  md5: src.origin + src.pathname,
  index: dir + 'index.js',
  configMd5: dir + 'index.config.js.md5',
  config: dir + 'index.config.js',
}
const masked = (u) => u.replace(/^(https?:\/\/)[^@/]*@/, '$1<user>:***@')

// ------------------------------------------------------- 下载（手动跟随跳转）

async function download(url, maxBytes) {
  const chain = []
  let current = url
  for (let hop = 0; hop <= 5; hop++) {
    const ctl = AbortController ? new AbortController() : null
    const timer = setTimeout(() => ctl?.abort(), TIMEOUT)
    let res
    try {
      res = await fetch(current, {
        redirect: 'manual',
        headers: {
          'User-Agent': UA,
          Accept: '*/*',
          ...(authHeader ? { Authorization: authHeader } : {}),
        },
        signal: ctl?.signal,
      })
    } finally {
      clearTimeout(timer)
    }
    const headers = Object.fromEntries(res.headers.entries())
    if (res.status >= 300 && res.status < 400 && res.headers.get('location')) {
      const next = new URL(res.headers.get('location'), current).toString()
      chain.push({ status: res.status, from: masked(current), to: masked(next) })
      // 模拟引用实现的 followSslRedirects(false)：https -> http 的降级跳转不自动跟
      if (new URL(current).protocol === 'https:' && new URL(next).protocol === 'http:') {
        throw new Error(`拒绝 HTTPS→HTTP 降级跳转: ${masked(next)}`)
      }
      current = next
      continue
    }
    // 流式限量，避免"先下载再判断"
    const reader = res.body.getReader()
    const chunks = []
    let size = 0
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      size += value.length
      if (size > maxBytes) {
        await reader.cancel()
        throw new Error(`响应超过上限 ${maxBytes} 字节`)
      }
      chunks.push(value)
    }
    return {
      status: res.status,
      finalUrl: masked(current),
      headers,
      chain,
      body: Buffer.concat(chunks),
      contentType: res.headers.get('content-type'),
    }
  }
  throw new Error('跳转次数过多')
}

const md5 = (buf) => createHash('md5').update(buf).digest('hex')
const parseMd5File = (buf) => {
  const m = String(buf).match(/(?:^|\s)([a-fA-F0-9]{32})(?:\s|$)/)
  return m ? m[1].toLowerCase() : null
}

// --------------------------------------------- 静态 JS 对象字面量解析器
// 刻意限制语法：JSON 兼容字面量 + JS 标识符键 + 注释 + 单引号 + 尾逗号。
// 参考实现（OKVideoMac ContractBCompanionConfigParser）就是这个思路：配置是数据，不是代码。

const MARKERS = [
  'var index_config_default =',
  'let index_config_default =',
  'const index_config_default =',
  'export default',
  'module.exports =',
  'exports.default =',
]

class StaticJS {
  constructor(s, i = 0) {
    this.s = s
    this.i = i
    this.count = 0
  }
  fail(msg) {
    throw new Error(`${msg} (offset ${this.i})`)
  }
  skip() {
    for (;;) {
      const before = this.i
      while (this.i < this.s.length && /\s/.test(this.s[this.i])) this.i++
      if (this.s.startsWith('//', this.i)) {
        const j = this.s.indexOf('\n', this.i)
        this.i = j < 0 ? this.s.length : j + 1
      } else if (this.s.startsWith('/*', this.i)) {
        const j = this.s.indexOf('*/', this.i + 2)
        this.i = j < 0 ? this.s.length : j + 2
      }
      if (this.i === before) break
    }
  }
  value(depth = 0) {
    if (depth > 64) this.fail('嵌套过深')
    if (++this.count > 100000) this.fail('值过多')
    this.skip()
    const c = this.s[this.i]
    if (c === '{') return this.object(depth)
    if (c === '[') return this.array(depth)
    if (c === '"' || c === "'") return this.string(c)
    if (c === '-' || (c >= '0' && c <= '9')) return this.number()
    for (const [kw, v] of [['true', true], ['false', false], ['null', null], ['undefined', null]]) {
      if (this.s.startsWith(kw, this.i) && !/[A-Za-z0-9_$]/.test(this.s[this.i + kw.length] || '')) {
        this.i += kw.length
        return v
      }
    }
    this.fail(`意外的字符 ${JSON.stringify(c)}`)
  }
  object(depth) {
    const out = {}
    this.i++ // {
    for (;;) {
      this.skip()
      if (this.s[this.i] === '}') { this.i++; return out }
      if (this.s[this.i] === ',') { this.i++; continue }
      const key = this.key()
      this.skip()
      if (this.s[this.i] !== ':') this.fail('键后缺少 :')
      this.i++
      out[key] = this.value(depth + 1)
      this.skip()
      if (this.s[this.i] === ',') this.i++
    }
  }
  array(depth) {
    const out = []
    this.i++ // [
    for (;;) {
      this.skip()
      if (this.s[this.i] === ']') { this.i++; return out }
      if (this.s[this.i] === ',') { this.i++; continue }
      out.push(this.value(depth + 1))
      this.skip()
      if (this.s[this.i] === ',') this.i++
    }
  }
  key() {
    const c = this.s[this.i]
    if (c === '"' || c === "'") return this.string(c)
    const m = /^[A-Za-z_$][A-Za-z0-9_$]*/.exec(this.s.slice(this.i))
    if (!m) this.fail('键名不合法')
    this.i += m[0].length
    return m[0]
  }
  string(quote) {
    let out = ''
    for (;;) {
      this.i++ // 开引号或拼接 +
      let chunk = ''
      for (;;) {
        const c = this.s[this.i]
        if (c === undefined) this.fail('字符串未闭合')
        if (c === '\\') {
          const n = this.s[++this.i]
          chunk +=
            n === 'n' ? '\n' : n === 't' ? '\t' : n === 'r' ? '\r' : n === 'u'
              ? String.fromCharCode(parseInt(this.s.substr(this.i + 1, 4), 16))
              : n
          if (n === 'u') this.i += 4
          this.i++
        } else if (c === quote) {
          this.i++
          break
        } else {
          chunk += c
          this.i++
        }
      }
      out += chunk
      this.skip()
      if (this.s[this.i] === '+') continue // esbuild 偶尔做字符串拼接
      return out
    }
  }
  number() {
    const m = /^-?(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)/.exec(this.s.slice(this.i))
    if (!m) this.fail('数字不合法')
    this.i += m[0].length
    return Number(m[0])
  }
}

/**
 * 从 index.config.js 源码里静态提取配置对象；失败返回 { error }。
 *
 * 注意：esbuild 的 CJS 产物里 `module.exports = __toCommonJS(...)` 往往出现在
 * 真正的数据赋值 `var index_config_default = {...}` **之前**，所以不能简单地"取最早的标记"。
 * 这里对所有标记位置逐个尝试静态解析，取解析成功且键最多的那个对象。
 */
function extractConfig(source) {
  const hits = []
  for (const marker of MARKERS) {
    for (let at = source.indexOf(marker); at >= 0; at = source.indexOf(marker, at + 1)) {
      hits.push({ marker, at, end: at + marker.length })
    }
  }
  if (!hits.length) return { error: '未找到任何赋值标记（不是一个可静态解析的配置包）' }
  hits.sort((a, b) => a.at - b.at)

  const attempts = []
  for (const hit of hits) {
    const parser = new StaticJS(source, hit.end)
    try {
      const value = parser.value()
      const keys = value && typeof value === 'object' && !Array.isArray(value) ? Object.keys(value).length : 0
      attempts.push({ ...hit, value, keys })
    } catch (e) {
      attempts.push({ ...hit, error: String(e.message || e) })
    }
  }

  const allMarkers = [...new Set(hits.map((h) => h.marker))]
  const good = attempts.filter((a) => a.value && a.keys > 0)
  if (!good.length) {
    return {
      allMarkers,
      error: attempts.find((a) => a.error)?.error || '所有标记之后都不是静态对象字面量',
             候选: attempts.map((a) => `${a.marker}@${a.at}${a.error ? '(失败)' : `(${a.keys} 键)`}`),
    }
  }
  good.sort((a, b) => b.keys - a.keys || a.at - b.at)
  const best = good[0]
  return {
    marker: best.marker,
    allMarkers,
    value: best.value,
    候选: attempts.map((a) => `${a.marker}@${a.at}${a.error ? '(失败)' : `(${a.keys} 键)`}`),
  }
}

// ------------------------------------------------------------- 分析

const CRED_KEYS = ['cookie', 'token', 'password', 'passwd', 'secret', 'refresh', 'refresh_token',
  'session', 'deviceId', 'credential', 'auth', 'apikey', 'apiKey']

// 宿主契约判别：引用实现（OKVideoMac NodeRuntimeContract.detect）的规则
//   三个标记全有 → contract-b（宿主集成型）；全无 → contract-a（独立服务型）；部分有 → 拒绝加载
const CONTRACT_MARKERS = ['catServerFactory', 'catDartServerPort', 'DEV_HTTP_PORT']

function classifyContract(source) {
  const flags = CONTRACT_MARKERS.map((m) => ({ 标记: m, 存在: source.includes(m) }))
  const n = flags.filter((f) => f.存在).length
  const kind =
    n === CONTRACT_MARKERS.length
      ? 'contract-b 宿主集成型（必须实现 bootstrap.js + /msg 桥）'
      : n === 0
        ? 'contract-a 独立服务型（bundle 自监听，宿主按约定探测就绪）'
        : '不支持的契约（标记不完整，引用实现会直接拒绝加载）'
  return { kind, flags }
}

/** 导出形态：bundle 必须能被 require/import 后拿到 { start(config) } */
function exportShape(source) {
  const head = source.slice(0, 4000)
  return {
    esbuild产物: /Object\.defineProperty|__toCommonJS|__defProp|__export/.test(head),
    含export_default: /export\s+default/.test(source),
    含module_exports: /module\.exports\s*=/.test(source),
    含start函数: /\bstart\s*[:(]\s*(async\s*)?/.test(source),
    nodeBuiltins: [...new Set([...source.matchAll(/require\("(?:node:)?([a-z_]+(?:\/[a-z_]+)?)"\)/g)].map((m) => m[1]))].length,
  }
}

/** 运行时依赖画像：这决定了任何"自写 shim"方案的可行性 */
function runtimeProfile(source) {
  const counts = new Map()
  for (const m of source.matchAll(/require\("(?:node:)?([a-z_]+(?:\/[a-z_]+)?)"\)/g)) {
    counts.set(m[1], (counts.get(m[1]) || 0) + 1)
  }
  const BUILTIN = new Set(['crypto', 'util', 'stream', 'zlib', 'path', 'url', 'events', 'assert',
    'https', 'http', 'worker_threads', 'buffer', 'tty', 'net', 'http2', 'tls', 'module', 'fs',
    'dns/promises', 'process', 'perf_hooks', 'os', 'string_decoder', 'querystring', 'vm', 'timers/promises'])
  const third = []
  for (const m of source.matchAll(/require\("([a-z@][a-z0-9@/._-]{2,32})"\)/g)) {
    if (!BUILTIN.has(m[1])) third.push(m[1])
  }
  return {
    内置模块数: counts.size,
    内置模块: [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 14).map(([k, v]) => `${k}(${v})`),
    第三方依赖: [...new Set(third)].filter((n) => !/^node:/.test(n)).slice(0, 18),
  }
}

function scanKeys(node, out = new Map(), depth = 0) {
  if (depth > 12 || node === null || typeof node !== 'object') return out
  if (Array.isArray(node)) { node.forEach((v) => scanKeys(v, out, depth + 1)); return out }
  for (const [k, v] of Object.entries(node)) {
    out.set(k, (out.get(k) || 0) + 1)
    scanKeys(v, out, depth + 1)
  }
  return out
}

/** 只统计凭据字段「值的长度」，绝不输出值本身 */
function credentialAudit(node, out = {}, depth = 0) {
  if (depth > 12 || node === null || typeof node !== 'object') return out
  if (Array.isArray(node)) { node.forEach((v) => credentialAudit(v, out, depth + 1)); return out }
  for (const [k, v] of Object.entries(node)) {
    if (CRED_KEYS.includes(k)) {
      const kind = typeof v === 'string' ? `string(len=${v.length})` : Array.isArray(v) ? `array(${v.length})` : typeof v
      out[k] = out[k] || {}
      out[k][kind] = (out[k][kind] || 0) + 1
    }
    credentialAudit(v, out, depth + 1)
  }
  return out
}

function listOf(container) {
  if (Array.isArray(container)) return container
  if (container && typeof container === 'object') {
    for (const k of ['list', 'items', 'sites', 'data', 'array', 'children']) {
      if (Array.isArray(container[k])) return container[k]
    }
    // 兜底：容器里任何一个非空数组
    for (const v of Object.values(container)) {
      if (Array.isArray(v) && v.length) return v
    }
  }
  return []
}

/** 描述一个容器的形状（不泄露内容） */
function shapeOf(container) {
  if (Array.isArray(container)) return `array(${container.length})`
  if (container && typeof container === 'object') {
    const keys = Object.keys(container)
    return `object{${keys.slice(0, 12).join(',')}${keys.length > 12 ? ',…' : ''}}(${keys.length} 键)`
  }
  return typeof container
}

/** 脱敏：凭据字段只留长度；URL 只留主机名 */
function redact(key, value) {
  if (CRED_KEYS.includes(key)) {
    return typeof value === 'string' ? `<redacted len=${value.length}>` : `<redacted ${typeof value}>`
  }
  if (typeof value === 'string' && /^https?:\/\//i.test(value)) {
    try { return `<url ${new URL(value).host}>` } catch { return '<url>' }
  }
  if (typeof value === 'string' && value.length > 120) return `<long string len=${value.length}>`
  return value
}

/** 递归脱敏（凭据只留长度、URL 只留主机名） */
function redactDeep(node, key = '') {
  if (Array.isArray(node)) return node.map((v) => redactDeep(v))
  if (node && typeof node === 'object') {
    return Object.fromEntries(Object.entries(node).map(([k, v]) => [k, redactDeep(v, k)]))
  }
  return redact(key, node)
}

const dumps = []
for (let i = 0; i < argv.length; i++) if (argv[i] === '--dump' && argv[i + 1]) dumps.push(argv[i + 1])

function describeSites(cfg) {
  const sites = listOf(cfg?.sites)
  return sites.map((s) => {
    const out = {}
    for (const [k, v] of Object.entries(s || {})) {
      if (k === 'ext' || k === 'header' || k === 'jar') { out[k] = shapeOf(v); continue }
      out[k] = redact(k, v)
    }
    return out
  })
}

/** 顶层键分类：模块键 / 提供者 / 主题 */
function classifyTopLevel(cfg) {
  const MODULE_KEYS = ['sites', 'pans', 'danmu', 'danmaku', 'color', 'video', 'read', 'comic', 'music', 'alist']
  const out = { 模块: {}, 提供者: [] }
  for (const [k, v] of Object.entries(cfg || {})) {
    if (MODULE_KEYS.includes(k)) { out.模块[k] = shapeOf(v); continue }
    if (v && typeof v === 'object') {
      const creds = Object.keys(v).filter((kk) => CRED_KEYS.includes(kk))
      out.提供者.push({ 键: k, 形状: shapeOf(v), 凭据字段: creds })
    }
  }
  return out
}

// --------------------------------------------------------------- 主流程

const report = {
  探测时间: new Date().toISOString(),
  订阅地址: masked(srcArg),
  包目录: masked(dir),
  文件: {},
  配置: {},
  站点目录: [],
  凭据字段: {},
  键名统计: {},
  结论: [],
}

console.log(`\n=== 通用接口体检 ===\n订阅: ${masked(srcArg)}\n`)

// 1) index.js.md5
const md5res = await download(URLS.md5, MAX_MD5_BYTES)
const expected = parseMd5File(md5res.body)
report.文件['index.js.md5'] = {
  status: md5res.status, bytes: md5res.body.length,
  contentType: md5res.contentType, value: expected,
}
console.log(`[1/4] index.js.md5     ${md5res.status}  ${md5res.body.length}B  md5=${expected}`)

// 2) index.js
const indexres = await download(URLS.index, MAX_INDEX_BYTES)
const indexText = indexres.body.toString('utf8')
const actual = md5(indexres.body)
const indexOk = expected && actual === expected
report.文件['index.js'] = {
  status: indexres.status, bytes: indexres.body.length, contentType: indexres.contentType,
  md5: actual, md5匹配: indexOk, etag: indexres.headers.etag, 跳转链: indexres.chain,
  finalUrl: indexres.finalUrl, contentTypeIsLie: !/javascript|text|octet-stream/i.test(indexres.contentType || ''),
}
console.log(`[2/4] index.js         ${indexres.status}  ${indexres.body.length}B  type=${indexres.contentType}  md5=${actual} ${indexOk ? '✓ 一致' : '✗ 不一致'}`)
if (indexres.chain.length) console.log(`      跳转链: ${indexres.chain.map((c) => `${c.status} → ${c.to}`).join(' | ')}`)
if (report.文件['index.js'].contentTypeIsLie) {
  console.log(`      ⚠ Content-Type 与实际内容不符（MIME 伪装）→ 客户端不得依赖 Content-Type 判断内容`)
}

const contract = classifyContract(indexText)
const shape = exportShape(indexText)
const profile = runtimeProfile(indexText)
report.契约 = contract
report.导出形态 = shape
report.运行时画像 = profile
console.log(`      宿主契约: ${contract.kind}  [${contract.flags.map((f) => `${f.标记}${f.存在 ? '✓' : '✗'}`).join(' ')}]`)
console.log(`      导出形态: esbuild=${shape.esbuild产物 ? '✓' : '✗'} export_default=${shape.含export_default ? '✓' : '✗'} module_exports=${shape.含module_exports ? '✓' : '✗'} start=${shape.含start函数 ? '✓' : '✗'}`)
console.log(`      运行时依赖: ${profile.内置模块数} 个内置模块  |  ${profile.内置模块.join(' ')}`)
if (profile.第三方依赖.length) console.log(`      第三方: ${profile.第三方依赖.join(' ')}`)

// 3) index.config.js.md5（可选）
let configExpected = null
try {
  const r = await download(URLS.configMd5, MAX_MD5_BYTES)
  configExpected = parseMd5File(r.body)
  report.文件['index.config.js.md5'] = { status: r.status, bytes: r.body.length, value: configExpected }
  console.log(`[3/4] index.config.md5 ${r.status}  md5=${configExpected}`)
} catch (e) {
  console.log(`[3/4] index.config.md5 不存在或失败（${e.message}）`)
}

// 4) index.config.js
let configSource = null
try {
  const r = await download(URLS.config, MAX_CONFIG_BYTES)
  configSource = r.body.toString('utf8')
  const cfgActual = md5(r.body)
  report.文件['index.config.js'] = {
    status: r.status, bytes: r.body.length, contentType: r.contentType, md5: cfgActual,
    md5匹配: configExpected ? cfgActual === configExpected : null,
  }
  console.log(`[4/4] index.config.js  ${r.status}  ${r.body.length}B  type=${r.contentType}  md5=${cfgActual}${configExpected ? (cfgActual === configExpected ? ' ✓' : ' ✗') : ''}`)
} catch (e) {
  console.log(`[4/4] index.config.js 失败: ${e.message}`)
}

// 静态解析配置
if (configSource) {
  const ex = extractConfig(configSource)
  const kind = /^\s*(var|let|const)\s+__|Object\.defineProperty/.test(configSource) ? 'esbuild/CJS 产物' : '纯字面量'
  report.配置.形态 = kind
  report.配置.赋值标记 = ex.allMarkers || [ex.marker]
  report.配置.候选标记 = ex.候选
  if (ex.error) {
    report.配置.解析错误 = ex.error
    console.log(`\n配置静态解析失败: ${ex.error}`)
  } else {
    const cfg = ex.value
    report.配置.顶层键 = Object.keys(cfg || {})
    report.配置.模块键 = ['sites', 'pans', 'danmu', 'color', 'video', 'read', 'comic', 'music']
      .filter((k) => k in (cfg || {}))
    const keys = [...scanKeys(cfg)].sort((a, b) => b[1] - a[1]).slice(0, 60)
    report.键名统计 = Object.fromEntries(keys)
    report.凭据字段 = credentialAudit(cfg)
    report.站点目录 = describeSites(cfg)

    const top = classifyTopLevel(cfg)
    report.结构 = top

    console.log(`\n--- 配置（静态提取，未执行 JS）---`)
    console.log(`形态: ${kind}`)
    console.log(`顶层键: ${report.配置.顶层键.join(', ')}`)
    console.log(`模块键形状: ${Object.entries(top.模块).map(([k, v]) => `${k}=${v}`).join('  ') || '(无)'}`)
    if (top.提供者.length) {
      console.log(`提供者（网盘/资源，共 ${top.提供者.length} 个）:`)
      for (const p of top.提供者) {
        console.log(`   · ${p.键.padEnd(18)} ${p.形状}${p.凭据字段.length ? `  凭据字段: ${p.凭据字段.join('/')}` : ''}`)
      }
    }
    console.log(`站点数: ${report.站点目录.length}`)
    for (const s of report.站点目录) {
      console.log(`   · ${JSON.stringify(s.name ?? s.title ?? '')}`)
      for (const [k, v] of Object.entries(s)) {
        if (k === 'name') continue
        console.log(`        ${k}: ${typeof v === 'object' ? JSON.stringify(v) : v}`)
      }
    }
    const creds = Object.entries(report.凭据字段)
    if (creds.length) {
      console.log(`凭据类字段（仅统计长度，不显示值）:`)
      for (const [k, v] of creds) console.log(`   · ${k}: ${Object.entries(v).map(([a, b]) => `${a}×${b}`).join(' ')}`)
      report.结论.push('配置 schema 含凭据字段：bundle 运行后的 data 目录会保存账号凭据，切勿外发或提交仓库')
    }

    for (const d of dumps) {
      const node = d.split('.').reduce((o, k) => (o == null ? o : o[k]), ex.value)
      console.log(`\n--- dump ${d} （已脱敏）---`)
      console.log(JSON.stringify(redactDeep(node), null, 2).slice(0, 4000))
    }
  }
}

// 结论
report.结论.unshift(
  `宿主契约：${contract.kind}`,
)
if (!indexOk) report.结论.push('MD5 不匹配：源站内容与校验文件不一致，不要缓存这份内容')
if (report.文件['index.js']?.bytes > 1024 * 1024) {
  report.结论.push(`包体积 ${(report.文件['index.js'].bytes / 1048576).toFixed(1)}MB：iOS 无 JIT 环境下的启动耗时要重点实测`)
}

mkdirSync(OUT, { recursive: true })
writeFileSync(join(OUT, 'index.js.md5'), md5res.body)
writeFileSync(join(OUT, 'index.js'), indexres.body)
if (configSource) writeFileSync(join(OUT, 'index.config.js'), configSource)
writeFileSync(join(OUT, 'sites.catalog.json'), JSON.stringify(report.站点目录, null, 2))
writeFileSync(join(OUT, 'report.json'), JSON.stringify(report, null, 2))

console.log(`\n--- 结论 ---`)
report.结论.forEach((c) => console.log('· ' + c))
console.log(`\n原始文件与报告已写入: ${OUT}\n`)
