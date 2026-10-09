'use strict'
/**
 * bootstrap.js —— 「通用接口」(Node 内置源) 的宿主引导脚本
 *
 * 这是**启动契约**的实现，协议来源：FongMi `nodejs/src/main/assets/nodejs/bootstrap.js`
 * （Apple 平台的等价实现见 OKVideoMac `NodeBundleRuntimeService.swift`）。
 *
 * 用法（由宿主调用，不要手工跑）:
 *   node bootstrap.js <index.js> <index.config.js> <dataRoot> <bridgePort> <token>
 *        argv[2]        argv[3]              argv[4]     argv[5]       argv[6]
 *
 * 它做六件事：
 *   1. 设置 bundle 约定的环境变量（停用自启动，改由宿主提供 server 工厂）
 *   2. 注入 globalThis.catServerFactory / catDartServerPort
 *   3. 给 http.request 打补丁：访问宿主 /msg 桥时自动带 X-CatVod-Token
 *   4. 把 bundle 真实监听的地址回传给宿主（serverStarted）
 *   5. require(index.config.js) 与 require(index.js)，调用 runtime.start(config)
 *   6. 失败时上报 nodeError 并退出
 */

const http = require('node:http')
const net = require('node:net')
const path = require('node:path')
const { pathToFileURL } = require('node:url')

const [, , indexPath, configPath, dataRoot, bridgePortText, token] = process.argv
const bridgePort = Number(bridgePortText)

if (!indexPath || !configPath || !dataRoot || !Number.isInteger(bridgePort) || !token) {
  console.error('[bootstrap] 用法: node bootstrap.js <index.js> <index.config.js> <dataRoot> <bridgePort> <token>')
  process.exit(2)
}

const TOKEN_HEADER = 'X-CatVod-Token'
let server = null
let runtime = null

// ---- 0. 编译缓存（iOS 无 JIT 环境下最值钱的一笔优化）
// 把"每次启动都要解析几 MB JS"变成"只有第一次解析"。
// Node >= 22.1 提供 module.enableCompileCache()（Node >= 22.8 才有这个函数名）。
// iOS 宿主会**提前**用环境变量设好 NODE_COMPILE_CACHE + NODE_COMPILE_CACHE_PORTABLE=1
// （环境变量必须早于 Node 启动才生效），这里就不重复启用；桌面跑时由本行自己开。
if (!process.env.NODE_COMPILE_CACHE) {
  try {
    require('node:module').enableCompileCache?.(path.join(dataRoot, '.compile-cache'))
  } catch {
    /* 忽略 */
  }
}

// ---- 1. 环境
process.env.CATVOD_DISABLE_AUTOSTART = '1' // 告诉 bundle：别自己 listen，用宿主给的 factory
process.env.HOST = '127.0.0.1'
process.env.PORT = '0'
process.env.DEV_HTTP_PORT = '0'
process.env.HOME = dataRoot
process.chdir(dataRoot)

// ---- 3. http.request 补丁：只有发往宿主 /msg 桥的请求才带 token
const originalHttpRequest = http.request

function isBridgeRequest(input, options = {}) {
  let host, port, requestPath
  let method = options.method
  if (typeof input === 'string' || input instanceof URL) {
    const target = new URL(input)
    host = target.hostname
    port = target.port || (target.protocol === 'https:' ? '443' : '80')
    requestPath = target.pathname
  } else if (input && typeof input === 'object') {
    host = input.hostname || input.host
    port = input.port
    requestPath = input.path || input.pathname
    method = input.method
  }
  return (
    String(method || 'GET').toUpperCase() === 'POST' &&
    (host === '127.0.0.1' || host === 'localhost') &&
    Number(port) === bridgePort &&
    String(requestPath || '').split('?', 1)[0] === '/msg'
  )
}

http.request = function authenticatedBridgeRequest(...args) {
  const input = args[0]
  const options = args[1] && typeof args[1] === 'object' ? args[1] : {}
  if (!isBridgeRequest(input, options)) return originalHttpRequest.apply(this, args)
  if (typeof input === 'string' || input instanceof URL) {
    const secured = { ...options, headers: { ...(options.headers || {}), [TOKEN_HEADER]: token } }
    if (args[1] && typeof args[1] === 'object') args[1] = secured
    else args.splice(1, 0, secured)
  } else {
    args[0] = { ...input, headers: { ...(input.headers || {}), [TOKEN_HEADER]: token } }
  }
  return originalHttpRequest.apply(this, args)
}

// ---- 4. 向宿主回报
function send(action, opt = {}) {
  const body = JSON.stringify({ action, opt })
  const request = http.request({
    host: '127.0.0.1',
    port: bridgePort,
    path: '/msg',
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
      [TOKEN_HEADER]: token,
    },
    timeout: 3000,
  })
  request.on('error', () => {})
  request.on('timeout', () => request.destroy())
  request.end(body)
}

function reportStarted() {
  const address = server && server.address()
  if (!address || typeof address !== 'object') return
  send('serverStarted', {
    address: `http://127.0.0.1:${address.port}`,
    token,
    pid: process.pid,
    version: process.version,
    arch: process.arch,
  })
  startListenerWatchdog()
}

// ---- 7. 本地服务自愈
// iOS 会在 App 被挂起时回收它的监听 socket：Node 还活着，但端口连不上了
// （真机实测：启动 85 秒后宿主请求报"无法连接服务器"，而 node_start 并没有返回）。
// 对策：每 10 秒从 Node 侧连一次自己；连不上就用**同一个端口**重建一个 server
// （换端口会让宿主手里的旧地址失效，所以必须原地重绑）。
let listenerWatchdog = null
let lastHandler = null
let rebindingNow = false

function startListenerWatchdog() {
  if (listenerWatchdog || !server) return
  const address = server.address()
  if (!address || typeof address !== 'object' || !address.port) return
  const port = address.port

  listenerWatchdog = setInterval(() => {
    if (rebindingNow) return
    const probe = net.connect({ host: '127.0.0.1', port })
    let settled = false
    const finish = (alive) => {
      if (settled) return
      settled = true
      probe.removeAllListeners()
      probe.destroy()
      if (!alive) rebind(port)
    }
    probe.setTimeout(2000)
    probe.once('connect', () => finish(true))
    probe.once('error', () => finish(false))
    probe.once('timeout', () => finish(false))
  }, 10000)
  listenerWatchdog.unref?.()
  console.log(`[bootstrap] 监听自愈已开启（每 10s 自检 127.0.0.1:${port}）`)
}

function rebind(port) {
  if (rebindingNow || !lastHandler) return
  rebindingNow = true
  console.warn(`[bootstrap] 监听已失效（App 挂起后 socket 被系统回收）→ 原地重绑 127.0.0.1:${port}`)

  const fresh = http.createServer(lastHandler)
  fresh.once('error', (error) => {
    console.warn(`[bootstrap] 重绑失败：${error && error.code ? error.code : error}`)
    rebindingNow = false
  })
  try {
    fresh.listen({ host: '127.0.0.1', port, exclusive: true }, () => {
      server = fresh
      console.warn(`[bootstrap] 已重新监听 http://127.0.0.1:${port}`)
      reportStarted()
      rebindingNow = false
    })
  } catch (error) {
    console.warn(`[bootstrap] 重绑异常：${error && error.message}`)
    rebindingNow = false
  }
}

// ---- 2. 注入宿主能力
globalThis.catDartServerPort = () => bridgePort

globalThis.catServerFactory = (handler) => {
  lastHandler = handler
  server = http.createServer(handler)
  const listen = server.listen.bind(server)
  // 强制只监听回环 + 随机端口：避免冲突，也避免把本地服务暴露到局域网
  server.listen = (...args) => {
    const callback = typeof args[args.length - 1] === 'function' ? args[args.length - 1] : undefined
    return listen({ host: '127.0.0.1', port: 0, exclusive: true }, callback)
  }
  server.once('listening', reportStarted)
  return server
}

// ---- 5. 加载 bundle
/** 优先 CJS require；遇到 ESM 语法则退回动态 import（esbuild 产物两种形态都有） */
async function loadModule(file) {
  const absolute = path.resolve(file)
  try {
    return require(absolute)
  } catch (error) {
    const message = String((error && error.message) || error)
    if (/Cannot use import statement|Unexpected token 'export'|require\(\) of ES Module|ERR_REQUIRE_ESM/i.test(message)) {
      return await import(pathToFileURL(absolute).href)
    }
    throw error
  }
}

async function main() {
  const configModule = await loadModule(configPath)
  const indexModule = await loadModule(indexPath)
  const config = (configModule && (configModule.default || configModule)) || {}
  runtime = indexModule && (indexModule.default || indexModule)
  if (!runtime || typeof runtime.start !== 'function') {
    throw new Error('Node bundle does not export start()')
  }
  await runtime.start(config)
}

main().catch((error) => {
  // ---- 6. 失败上报
  send('nodeError', { message: String((error && (error.stack || error.message)) || error), token })
  setTimeout(() => process.exit(1), 100)
})
