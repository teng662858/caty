#!/usr/bin/env node
/**
 * export-session.mjs —— 把 ZCode 会话导出成可读的 Markdown
 *
 * 用途：让"对话"变成项目里的文件，从此不依赖会话本身（换任务、换项目、换电脑都还在）。
 * 只读数据库，不修改任何东西。
 *
 * 用法:
 *   node tools/export-session.mjs                       # 导出最近一次会话
 *   node tools/export-session.mjs --session sess_xxx     # 指定会话
 *   node tools/export-session.mjs --out docs/07-xxx.md   # 指定输出
 *   node tools/export-session.mjs --with-reasoning       # 附上模型的思考过程（默认不含）
 *   node tools/export-session.mjs --tool-chars 2000      # 工具输出保留字数（默认 500）
 *
 * 安全：输出前自动脱敏（URL 里的 user:pass@ → user:***@；常见口令字面量）。
 */

import { DatabaseSync } from 'node:sqlite'
import { existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'

const argv = process.argv.slice(2)
const opt = (name, def) => {
  const i = argv.indexOf(`--${name}`)
  return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : def
}
const has = (f) => argv.includes(`--${f}`)

const DB = opt('db', 'C:/Users/63089/.zcode/cli/db/db.sqlite')
const WITH_REASONING = has('with-reasoning')
const TOOL_CHARS = Number(opt('tool-chars', 500))
const OUT = resolve(opt('out', 'docs/session-export.md'))

// ── 脱敏 ────────────────────────────────────────────────────────────
const SECRETS = ['wexfnw', 'woleigedouer'] // 本次会话里出现过的口令字面量
function redact(s) {
  let t = String(s ?? '')
  for (const sec of SECRETS) {
    t = t.split(`${sec}:${sec}`).join('<user>:***')
    t = t.split(sec).join('<user>')
  }
  t = t.replace(/(\w+:\/\/)([^:@/\s]+):([^@/\s]+)@/g, '$1$2:***@') // 通用 URL 凭据
  t = t.replace(/(-u\s+')([^':\s]+):([^']+)(')/g, '$1$2:***$4')     // curl -u user:pass
  return t
}
/** JSON 里的 cookie/token 等字段值脱敏（只留长度） */
function redactJsonSecrets(s) {
  return String(s).replace(
    /("(?:cookie|token|refresh_token|password|passwd|secret|auth)"\s*:\s*")([^"]{1,400})(")/gi,
    (_, a, b, c) => `${a}<redacted len=${b.length}>${c}`,
  )
}

// ── 路径归一化 ──────────────────────────────────────────────────────
// 项目搬过家（catnode-ios → Caty → D:\Zcode\Catys），历史记录里的旧绝对路径
// 会让链接失效。导出时统一指向当前位置，并在文件头说明。
const PATH_FIXES = [
  ['C:/Users/63089/.zcode/workspace/default/catnode-ios/', 'D:/Zcode/Catys/'],
  ['C:\\Users\\63089\\.zcode\\workspace\\default\\catnode-ios\\', 'D:\\Zcode\\Catys\\'],
  ['C:/Users/63089/.zcode/workspace/default/Caty/', 'D:/Zcode/Catys/'],
  ['C:\\Users\\63089\\.zcode\\workspace\\default\\Caty\\', 'D:\\Zcode\\Catys\\'],
]
function fixPaths(s) {
  let t = String(s ?? '')
  for (const [from, to] of PATH_FIXES) t = t.split(from).join(to)
  // 导出文件位于 docs/ 下，指向仓库根文件的相对链接要退一级
  t = t.replace(/\]\((?!\.\.\/|https?:|#)(AGENTS\.md|README\.md)\)/g, '](../$1)')
  return t
}

const cut = (s, n) => {
  const t = String(s ?? '')
  return t.length <= n ? t : `${t.slice(0, n)}\n…（输出共 ${t.length} 字符，此处截断）`
}
const oneLine = (s, n = 200) => String(s ?? '').replace(/\s+/g, ' ').trim().slice(0, n)

/** 统一清洗：**先脱敏再截断**（顺序不能反，否则口令可能被截成半截而漏脱敏），最后修正路径 */
const clean = (s, n = Number.MAX_SAFE_INTEGER) => fixPaths(cut(redactJsonSecrets(redact(s)), n))

// ── 读库 ────────────────────────────────────────────────────────────
if (!existsSync(DB)) {
  console.error(`找不到数据库：${DB}\n（如有需要可用 --db 指定）`)
  process.exit(1)
}
const db = new DatabaseSync(DB, { readOnly: true })

let sid = opt('session', null)
if (!sid) {
  const row = db.prepare('SELECT id FROM session ORDER BY time_updated DESC LIMIT 1').get()
  if (!row) { console.error('库里没有任何会话'); process.exit(1) }
  sid = row.id
}
const sess = db.prepare('SELECT id,title,directory,time_created,task_type FROM session WHERE id=?').get(sid)
if (!sess) { console.error(`找不到会话 ${sid}`); process.exit(1) }

const messages = db.prepare('SELECT id,data,sequence FROM message WHERE session_id=? ORDER BY sequence').all(sid)
const parts = db.prepare('SELECT message_id,data,sequence FROM part WHERE session_id=? ORDER BY sequence').all(sid)
const byMsg = new Map()
for (const p of parts) {
  if (!byMsg.has(p.message_id)) byMsg.set(p.message_id, [])
  byMsg.get(p.message_id).push(p)
}

// ── 生成 ────────────────────────────────────────────────────────────
const ts = (ms) => new Date(ms).toLocaleString('zh-CN', { hour12: false })
let toolCount = 0
let tokensIn = 0
let tokensOut = 0
const lines = []

lines.push(`# 会话记录：${sess.title || '(无标题)'}`)
lines.push('')
lines.push(`| 项 | 值 |`)
lines.push(`|---|---|`)
lines.push(`| 会话 ID | \`${sid}\` |`)
lines.push(`| 工作目录 | \`${sess.directory}\` |`)
lines.push(`| 开始时间 | ${ts(sess.time_created)} |`)
lines.push(`| 导出时间 | ${ts(Date.now())} |`)
lines.push(`| 规模 | ${messages.length} 条消息 / ${parts.length} 个片段 |`)
lines.push('')
lines.push('> 本文件由 `tools/export-session.mjs` 自动生成，**已脱敏**（订阅地址里的口令写为 `***`）。')
lines.push('> 默认不收录模型的推理过程（加 `--with-reasoning` 可包含）；工具输出保留前若干字符。')
lines.push('> 历史记录里的旧项目路径（`catnode-ios` / `Caty`）已自动归一化到当前位置 `D:/Zcode/Catys`。')
lines.push('')
lines.push('---')
lines.push('')

let turn = 0
for (const m of messages) {
  let md
  try { md = JSON.parse(m.data) } catch { continue }
  const role = md.role
  const ps = byMsg.get(m.id) || []

  const texts = ps.filter((p) => JSON.parse(p.data).type === 'text').map((p) => JSON.parse(p.data))
  const tools = ps.filter((p) => JSON.parse(p.data).type === 'tool').map((p) => JSON.parse(p.data))
  const reasons = ps.filter((p) => JSON.parse(p.data).type === 'reasoning').map((p) => JSON.parse(p.data))
  const files = ps.filter((p) => JSON.parse(p.data).type === 'file').map((p) => JSON.parse(p.data))

  const userText = texts.filter((t) => role === 'user').map((t) => t.text).join('\n\n')
  const asstText = texts.filter((t) => role !== 'user' && !t.synthetic).map((t) => t.text).join('\n\n')

  if (role === 'user' && userText.trim()) {
    turn++
    lines.push(`## 👤 你 · 第 ${turn} 轮`)
    lines.push('')
    lines.push(clean(userText))
    for (const f of files) lines.push(`\n（附了一张图：\`${f.filename || f.mime}\`）`)
    lines.push('')
  }

  if (tools.length) {
    lines.push(`<details><summary>🛠 调用了 ${tools.length} 个工具（点开看）</summary>`)
    lines.push('')
    for (const t of tools) {
      toolCount++
      const name = t.tool || t.state?.tool || '?'
      const st = t.state || {}
      const input = st.input || st.args || {}
      const summary = clean(
        input.description || input.command || input.file_path || input.query || input.path || JSON.stringify(input),
        220,
      )
      lines.push(`**${toolCount}. \`${name}\`** — ${summary}`)
      const out = st.output || st.result || st.content || ''
      if (out) {
        lines.push('')
        lines.push('```text')
        lines.push(clean(typeof out === 'string' ? out : JSON.stringify(out), TOOL_CHARS))
        lines.push('```')
      }
      lines.push('')
    }
    lines.push('</details>')
    lines.push('')
  }

  if (asstText.trim()) {
    lines.push(`### 🤖 我的回答${turn ? `（第 ${turn} 轮）` : ''}`)
    lines.push('')
    lines.push(clean(asstText))
    lines.push('')
  }

  if (WITH_REASONING && reasons.length) {
    lines.push(`<details><summary>🧠 推理过程（${reasons.length} 段）</summary>`)
    lines.push('')
    for (const r of reasons) lines.push(clean(r.text, 1200))
    lines.push('')
    lines.push('</details>')
    lines.push('')
  }

  const usage = md.tokens
  if (usage) {
    tokensIn += usage.input || 0
    tokensOut += usage.output || 0
  }
}

const header = lines.slice(0, 11)
const body = lines.slice(11)
const footer = [
  '',
  '---',
  '',
  '## 统计',
  '',
  `- 工具调用：**${toolCount}** 次`,
  `- Token：输入 ${tokensIn.toLocaleString()} / 输出 ${tokensOut.toLocaleString()}`,
  '',
].join('\n')

const outText = [...header, body.join('\n'), footer].join('\n')
mkdirSync(dirname(OUT), { recursive: true })
writeFileSync(OUT, outText, 'utf8')

console.log(`✅ 已导出：${OUT}`)
console.log(`   会话：${sess.title}`)
console.log(`   ${messages.length} 条消息 · ${toolCount} 次工具调用 · ${(outText.length / 1024).toFixed(0)} KB`)
