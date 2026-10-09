#!/usr/bin/env node
/**
 * check-swift-heuristics.mjs —— Swift 源码的**粗略**静态自查（Windows 上没有 Swift 编译器时的兜底）
 *
 * 能查：
 *   1. 括号 / 花括号 / 方括号是否平衡（先剥掉注释与字符串字面量）
 *   2. 常见事故：Swift 6 才需要的写法、忘了删的占位符、非 ASCII 引号、CRLF 混用
 *   3. 文件清单与行数总览（交付时对齐用）
 *
 * **查不出**：类型错误、API 用法错误、并发隔离错误 —— 那些只能在 Mac 上 `Cmd+B` 才知道。
 * 所以它的定位是"上 Mac 之前先排除低级错误"，不是编译替代品。
 *
 * 用法: node tools/check-swift-heuristics.mjs [目录，默认 ios]
 */

import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

const ROOT = process.argv[2] || 'ios'

const files = []
;(function walk(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name)
    if (entry.isDirectory()) walk(full)
    else if (entry.name.endsWith('.swift') || entry.name.endsWith('.h')) files.push(full)
  }
})(ROOT)

/** 剥掉注释与字符串字面量，便于做括号计数 */
function strip(source) {
  let out = ''
  let i = 0
  const n = source.length
  while (i < n) {
    const two = source.slice(i, i + 2)
    if (two === '//') {
      while (i < n && source[i] !== '\n') i++
    } else if (two === '/*') {
      const end = source.indexOf('*/', i + 2)
      i = end === -1 ? n : end + 2
    } else if (source[i] === '"') {
      // 处理 """ 多行字符串
      if (source.slice(i, i + 3) === '"""') {
        const end = source.indexOf('"""', i + 3)
        i = end === -1 ? n : end + 3
      } else {
        i++
        while (i < n && source[i] !== '"') {
          if (source[i] === '\\') i++
          i++
        }
        i++
      }
    } else {
      out += source[i]
      i++
    }
  }
  return out
}

let problems = 0
const rows = []

for (const file of files.sort()) {
  const raw = readFileSync(file, 'utf8')
  const code = strip(raw)
  const count = (ch) => code.split(ch).length - 1
  const brace = count('{') - count('}')
  const paren = count('(') - count(')')
  const bracket = count('[') - count(']')

  const issues = []
  if (brace) issues.push(`花括号不平衡 (${brace > 0 ? '+' : ''}${brace})`)
  if (paren) issues.push(`圆括号不平衡 (${paren > 0 ? '+' : ''}${paren})`)
  if (bracket) issues.push(`方括号不平衡 (${bracket > 0 ? '+' : ''}${bracket})`)
  if (/[“”‘’]/.test(raw)) issues.push('出现中文智能引号（Swift 里必须是 ASCII 引号）')
  if (/<<<<<<<|>>>>>>>/.test(raw)) issues.push('存在未解决的合并冲突标记')
  if (/\bTODO\b|\bFIXME\b|\bXXX\b/.test(raw)) issues.push('留有 TODO/FIXME（确认是否有意为之）')
  if (raw.includes('\r\n')) issues.push('含 CRLF 换行（建议统一 LF）')
  if (!raw.endsWith('\n')) issues.push('文件末尾没有换行')

  const lines = raw.split('\n').length
  if (issues.length) problems += issues.length
  rows.push({ file: relative('.', file), lines, issues })
}

const width = Math.max(...rows.map((r) => r.file.length))
for (const row of rows) {
  const flag = row.issues.length ? '  ✗ ' + row.issues.join('；') : '  ✓'
  console.log(`${row.file.padEnd(width)}  ${String(row.lines).padStart(4)} 行${flag}`)
}

console.log(
  problems
    ? `\n✗ 共 ${problems} 处需要看一眼（见上）`
    : `\n✓ ${rows.length} 个文件：括号平衡、引号正常、无冲突标记`
)
console.log('提醒：这只排除低级错误；类型/API/并发问题必须在 Mac 上 Cmd+B 才知道。')
process.exit(problems ? 1 : 0)
