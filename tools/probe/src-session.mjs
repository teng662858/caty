#!/usr/bin/env node
/**
 * src-session.mjs —— 起一个"常驻"的真源会话，方便一边打请求一边看日志
 *
 * 和 tools/probe/site-probe.mjs 用同一套启动方式（同一个 bootstrap.js + /msg 桥），
 * 区别是它**不自动打请求、也不退出**：启动后打印服务地址，然后一直活着，
 * 你可以用 curl 打任何路由，同时它的全部 stdout/stderr 都会打到本进程输出（可重定向到文件）。
 *
 * ⚠️ 执行第三方 Node 程序（缓存里的 index.js）。只对你信任的源跑。
 *
 * 用法:
 *   node tools/probe/src-session.mjs [bundle目录] [--port N] [--ua okhttp/3.15.0]
 */

import { randomBytes } from 'node:crypto'
import { existsSync, readdirSync, statSync } from 'node:fs'
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
const opt = (name, def) => (opts[name] === undefined || opts[name] === true ? def : String(opts[name]))

function findBundle() {
  if (positional[0]) return resolve(positional[0])
  const dataDir = resolve(ROOT, 'host-data')
  const candidates = []
  for (const name of readdirSync(dataDir)) {
    for (const sub of ['active', '']) {
      const index = join(dataDir, name, sub, 'index.js')
      if (existsSync(index)) candidates.push({ dir: join(dataDir, name, sub), size: statSync(index).size })
    }
  }
  candidates.sort((a, b) => b.size - a.size)
  return candidates[0].dir
}

const BUNDLE = findBundle()
const BRIDGE_PORT = Number(opt('port', '0')) || 0
const BOOTSTRAP_FILE = resolve(ROOT, opt('bootstrap', BOOTSTRAP))

const freePort = () =>
  new Promise((res, rej) => {
    const s = net.createServer()
    s.on('error', rej)
    s.listen(0, '127.0.0.1', () => {
      const port = s.address().port
      s.close(() => res(port))
    })
  })

const TOKEN = randomBytes(16).toString('hex')
const bridgePort = BRIDGE_PORT || (await freePort())

const bridge = http.createServer((req, res) => {
  if (req.method !== 'POST' || !req.url.startsWith('/msg')) return res.writeHead(404).end()
  if (req.headers['x-catvod-token'] !== TOKEN) return res.writeHead(403).end()
  let body = ''
  req.on('data', (c) => { body += c })
  req.on('end', () => {
    res.writeHead(200, { 'content-type': 'application/json' }).end('{}')
    console.log(`[桥] ${String(body).slice(0, 400)}`)
  })
})
await new Promise((r) => bridge.listen(bridgePort, '127.0.0.1', r))
console.log(`[宿主] 桥端口 ${bridgePort}  token=${TOKEN.slice(0, 6)}…`)

const child = spawn(process.execPath, [BOOTSTRAP_FILE, join(BUNDLE, 'index.js'), join(BUNDLE, 'index.config.js'), BUNDLE, String(bridgePort), TOKEN], {
  cwd: BUNDLE,
  stdio: ['ignore', 'pipe', 'pipe'],
  env: { ...process.env, CATVOD_DISABLE_AUTOSTART: '1' },
})
child.stdout.on('data', (c) => process.stdout.write(String(c)))
child.stderr.on('data', (c) => process.stdout.write(String(c)))
child.on('exit', (code) => {
  console.log(`[宿主] 源进程退出 code=${code}`)
  process.exit(0)
})

console.log(`[宿主] bundle=${BUNDLE}\n[宿主] 等待源监听…（看下面 "listening on" 那一行拿端口）`)
setInterval(() => {}, 1 << 30)
