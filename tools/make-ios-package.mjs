#!/usr/bin/env node
/**
 * make-ios-package.mjs —— 把 ios/ 重新打成给 Mac 的交付包
 *
 * 用法: node tools/make-ios-package.mjs
 * 产物: dist/Caty-P2P3-代码包.zip（含顶层文件夹 + 「代码包说明.md」）
 *
 * 为什么要有这个：改完 ios/ 下的代码后必须重打包，否则 Mac 上编译的是旧代码。
 * 打包前会先跑一遍 Swift 粗略自查与 P2 链路桌面预演，任一失败就不出包。
 */

import { execFileSync } from 'node:child_process'
import { cpSync, existsSync, mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const REPO = process.cwd()
const IOS = join(REPO, 'ios')
const DIST = join(REPO, 'dist')
const PACK_NAME = 'Caty-P2P3-代码包'
const PACK_DIR = join(DIST, 'pack', PACK_NAME)
const ZIP = join(DIST, `${PACK_NAME}.zip`)

function run(label, args) {
  process.stdout.write(`· ${label} … `)
  try {
    execFileSync(process.execPath, args, { cwd: REPO, stdio: 'pipe' })
    console.log('通过')
  } catch (error) {
    console.log('失败')
    console.error(String(error.stdout || '') + String(error.stderr || ''))
    process.exit(1)
  }
}

run('Swift 粗略自查', ['tools/check-swift-heuristics.mjs', 'ios'])
run('P2 链路桌面预演', ['tools/host/p2-selftest.mjs'])

rmSync(PACK_DIR, { recursive: true, force: true })
mkdirSync(PACK_DIR, { recursive: true })
cpSync(IOS, PACK_DIR, { recursive: true })

// 包内说明（Mac 上没有仓库文档，给一份最短的）
const readme = `# Caty · P2 + P3 代码包（给 Mac 用）

完整逐步说明在仓库 docs/08-P2操作卡.md；这是一句话版：

1. 下载 NodeMobile（Node 24 线）：https://github.com/digidem/nodejs-mobile/releases/tag/v24.20.0-0
   取 nodejs-mobile-ios-lite-24.20.0-0.zip → 解压出 NodeMobile.xcframework → 放到工程目录 Frameworks/ 下。
2. 把本包的 Sources/、Resources/、Caty-Bridging-Header.h 拷到工程目录（与 Caty.xcodeproj 同级），
   Xcode 里 Add Files to "Caty"… → Create groups → Add to targets 勾 Caty。
   然后删掉 Xcode 自动生成的 CatyApp.swift 与 ContentView.swift（两个 @main 会冲突）。
3. NodeMobile.xcframework 拖进工程，General 页确认 Embed & Sign。
4. Build Settings：INFOPLIST_FILE=Resources/Info.plist、GENERATE_INFOPLIST_FILE=No、
   SWIFT_OBJC_BRIDGING_HEADER=Caty-Bridging-Header.h、Swift Strict Concurrency Checking=Minimal、
   Swift Language Version=Swift 5。
5. Cmd+R → 打开「诊断」tab → 期望 🟢 已就绪 + v24.x + serverStarted 地址。把「复制日志（已脱敏）」发回。

报错就把原文整段发回来。
`
writeFileSync(join(PACK_DIR, '代码包说明.md'), readme, 'utf8')

rmSync(ZIP, { force: true })
execFileSync('powershell.exe', [
  '-NoProfile', '-Command',
  `Compress-Archive -Path '${PACK_DIR}' -DestinationPath '${ZIP}' -Force`,
], { stdio: 'pipe' })

const files = []
;(function walk(dir, prefix = '') {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name
    if (entry.isDirectory()) walk(join(dir, entry.name), rel)
    else files.push(rel)
  }
})(PACK_DIR)

console.log(`\n✓ 已打包 ${ZIP}`)
console.log(`  含 ${files.length} 个文件：`)
for (const f of files.sort()) console.log(`   · ${f}`)
if (!existsSync(ZIP)) process.exit(1)
