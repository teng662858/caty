'use strict'
/**
 * bootstrap-trace.js —— 排查用的 bootstrap 包装：把真源的**每一次出站 HTTP 请求**打出来
 *
 * 用法（和 bootstrap.js 完全一样，只是多了 TRACE_FILTER 环境变量可过滤）：
 *   node tools/probe/bootstrap-trace.js <index.js> <index.config.js> <dataRoot> <bridgePort> <token>
 *
 * 它只记录、不改变行为：先给 http/https.request 套一层日志，再加载真正的 bootstrap.js。
 * 排查"某个站点打不开"时，能直接看到源去请求了哪个上游地址、返回什么。
 */

const path = require('node:path')

const FILTER = process.env.TRACE_FILTER || ''

function describe(args) {
  const input = args[0]
  const options = args[1] && typeof args[1] === 'object' ? args[1] : {}
  try {
    if (typeof input === 'string' || input instanceof URL) return String(input)
    if (input && typeof input === 'object') {
      const protocol = input.protocol || options.protocol || 'http:'
      const host = input.hostname || input.host || options.hostname || options.host || '?'
      const port = input.port || options.port || ''
      const requestPath = input.path || input.pathname || options.path || ''
      return `${protocol}//${host}${port ? ':' + port : ''}${requestPath}`
    }
  } catch {
    /* 忽略 */
  }
  return String(input)
}

for (const mod of [require('node:http'), require('node:https')]) {
  const original = mod.request
  mod.request = function tracedRequest(...args) {
    const url = describe(args)
    if (FILTER && !url.includes(FILTER)) return original.apply(this, args)
    const started = Date.now()
    const req = original.apply(this, args)
    console.log(`[TRACE→] ${url}`)
    req.on('response', (res) => {
      const ms = Date.now() - started
      const size = res.headers['content-length'] || '?'
      console.log(`[TRACE←] ${res.statusCode} ${ms}ms ${size}B ${url}`)
    })
    req.on('error', (error) => {
      const ms = Date.now() - started
      console.log(`[TRACE✗] ${ms}ms ${error.code || error.message} ${url}`)
    })
    return req
  }
}

require(path.join(__dirname, '..', 'host', 'bootstrap.js'))
