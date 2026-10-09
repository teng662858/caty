# Caty 小白开发手册（从零到装进手机）

> 这份文档是**给你个人看的操作手册**：每一步写清"你点什么、我做什么、做完怎么验证、卡住怎么办"。
> 需要背景知识时回看 [00-protocol-spec.md](00-protocol-spec.md)（协议）、[01-dev-plan.md](01-dev-plan.md)（计划）、
> [02-ui-spec.md](02-ui-spec.md)（界面）。

---

## 1. 先回答："只做 iPhone 也要那么久吗？"

**要。但原因不是 iPhone/iPad。** 只做 iPhone 大约只能省 **1–2 天**（就是 iPad 侧栏适配那点活）。

时间是这么花掉的：

| 花时间的部分 | 估算 | 能不能压缩 |
|---|---|---|
| 写代码（我） | ≈ 3 天工作量 | 已经是最快（我按整包给，你复制粘贴） |
| **在 macOS 上把环境搭起来**（装 Xcode、登录账号、建工程） | 0.5–1 天 | ❌ 不能，硬件与账号问题 |
| **首次把 App 装进你的 iPhone**（开发者模式、信任证书、签名报错） | 0.5–1 天 | ❌ 不能，小白必卡，但我会带你过 |
| **把 Node 运行时在 iOS 上跑通**（技术核心，最大的不确定性） | 1–2 天 | ⚠️ 部分（取决于无 JIT 下的性能） |
| 协议对接 + 缓存 + 站点层 + 播放器能播 | 2–3 天 | ⚠️ 部分 |
| **真机反复验证与排错**（每次改完要编译、装、试） | 3–5 天 | ❌ 不能，往返次数决定 |
| 界面打磨到"高级清爽" | 5–7 天 | ✅ 可砍（先能用再好看） |

**三条时间线，你自己选：**

| 目标 | 工期 | 包含 |
|---|---|---|
| **A. 能播**（最小可用） | **5–8 个工作日** | 导入源 → 一个文字列表 → 点进去能播出画面。界面很丑但不影响用 |
| **B. 日常可用**（推荐） | **约 3 周** | A + 完整界面（设计稿那 8 个屏）+ 搜索/收藏/历史 + 源管理 |
| **C. 全功能** | **6–8 周** | B + libmpv 硬解/字幕/弹幕渲染 + 直播 EPG + WebDAV + iPad |

**唯一能大幅压缩的做法**：先按 A 做，能用之后再迭代到 B。A 的代码 90% 在 B 里能复用，不会白写。

**一个必须说清楚的事实**：**有 Mac 会快很多**（改一次代码 → `Cmd+R`，几十秒）。
没有 Mac 也**不再是"不能开工"**了 —— 我们已经有可用通路（见 **[09-没有Mac也能装到手机.md](09-没有Mac也能装到手机.md)**）：

```
Windows 推代码 → GitHub 免费的 macOS 机器编译出未签名 ipa → Windows 上用 Sideloadly 签名装进手机
```

代价是每次改代码要"推送 → 等 5–8 分钟 → 下载 ipa → 重新签名"。
如果你以后能借到/买到一台 Mac（二手 Mac mini M 系 ≈ 2500–3500 元，或租云 Mac），那条路依然是首选。

---

## 2. 你要准备什么

### 必需
| 项 | 说明 | 成本 |
|---|---|---|
| **Mac**（任意型号，能装最新 Xcode 即可） | 开发与编译的唯一途径 | 借用 0 / 二手 Mac mini M 系 ≈ 2500–3500 元 / 云 Mac ≈ 100–300 元/月 |
| **iPhone**（你的 iOS 27.0.1 就行） | 目标设备 | 已有 |
| **Apple ID** | 免费即可（用于签名） | 0 |
| 数据线 | 首次连接要在 Xcode 里配对 | 已有 |

### 可选但强烈建议
| 项 | 好处 | 成本 |
|---|---|---|
| **付费开发者账号** | 证书 1 年有效，**不用每 7 天续签**；能用更多 App | $99/年（≈720 元） |
| GRDB / libmpv 等依赖 | 我全程给你 SPM 配置，不用你折腾 | 0 |

### 软件（我列清单，你按顺序装）
1. **Xcode**（App Store 搜 Xcode，免费，约 10–15 GB，装完还要它自己下载一次 iOS 平台组件）
   → 版本要求：**必须 ≥ 能支持你 iPhone 上 iOS 27 的那个版本**，所以直接装 App Store 里的最新版即可。
2. 装完后**打开一次 Xcode**，在 `Xcode › Settings › Accounts` 里用你的 Apple ID 登录（这一步不做，签名一定失败）。
3. Node.js（你这台 Windows 上已有 v24，Mac 上也要装一个，用于第 0 步验证工具）。

---

## 3. 分工：你只做三件事

**我负责**：所有代码（Swift / JS / 配置 / 脚本）、所有文档、所有排错方案。
**你负责**（只有这三件）：

1. **在 Mac 上执行我给的命令**（复制粘贴即可，我会写出完整命令）
2. **把报错原文贴回来**（不要概括成"报错了"，要**原文全文**——我 90% 的排错靠它）
3. **在手机上点一下，告诉我现象**（黑屏？白屏？卡住？闪退？）

**节奏**：每天我推进一个"可编译的包"，你花 20–40 分钟把它编译+装到手机，把结果回传。
这样即使你是小白，也不会卡在"看不懂"上——因为**不需要你看懂**，只需要跑和贴报错。

---

## 4. 分阶段操作手册（P0–P6）

> 每一步都有：🎯目标 · 👉你要做的 · ✅验收标准 · ⛔卡住怎么办

### P0 · 环境与骨架（半天）

🎯 有一台能编译 iOS App 的 Mac，Xcode 登录过 Apple ID，工程能建出来。

👉 你要做的：
1. 装 Xcode（App Store），打开一次，`Xcode › Settings › Accounts` 登录 Apple ID。
2. 建一个空项目验证环境：`File › New › Project › iOS › App`，Product Name 填 `Caty`，
   Interface 选 **SwiftUI**，Language 选 **Swift**，Bundle Identifier 填 `com.你的名字.caty`，最低版本选 **iOS 17.0**。
3. 直接 `Cmd + R` 跑到**模拟器**上，看会不会出现白屏 App。

✅ 能跑到模拟器 = 环境 OK。
⛔ 卡住：报 `Unable to create a provisioning profile` → 说明第 1 步账号没登录成功；把报错原文给我。

---

### P1 · 先把 App 装进你自己的手机（半天–1 天）——**别跳过这步**

🎯 这一步不写任何功能，目的只有一个：**把"签名/安装"这件最容易翻车的事先解决掉。**

👉 你要做的：
1. 用数据线连 iPhone，手机上若弹「信任此电脑」→ 点信任。
2. iPhone 上：`设置 › 隐私与安全性 › 开发者模式` → 打开 → 重启手机（**iOS 16 起必须有这一步**）。
3. Xcode 顶部设备选成你的 iPhone（不是模拟器），`Cmd + R`。
4. 手机上会提示"不受信任的开发者" → `设置 › 通用 › VPN 与设备管理 › 开发者 App` → 信任你的 Apple ID。
5. 再运行一次。

✅ 你手机上出现一个白屏但能打开的 Caty App。
⛔ 常见报错看第 7 节速查表（前 6 条都是这一步的）。

> **为什么必须先做这步**：如果等写了 3000 行代码才发现签名装不上去，你会以为是代码问题，实际是环境问题。

---

### P2 · 集成 Node 运行时（1–2 天）· **技术核心**

🎯 App 里能跑起一段 JS，并成功回调 Swift。

> ⭐ **这一包的代码已经写好了**：逐条点击说明在 **[08-P2操作卡.md](08-P2操作卡.md)**，照着做即可。
> 开工前先在 Windows 上跑一次桌面预演（10 秒，不下载、不执行第三方代码）：
> ```bash
> cd /d/Zcode/Catys && node tools/host/p2-selftest.mjs
> ```
> 看到 `✓ P2 链路自检通过` 再上 Mac。

👉 你要做的（详细版见 07 文档）：把我给的 `Sources/`、`Resources/`、`Caty-Bridging-Header.h`
放进工程 → 拖入 `NodeMobile.xcframework`（Link + **Embed & Sign**）→ 改 4 个 Build Settings →
`Cmd + R`。

已给的东西：
- **运行时来源已定**：`digidem/nodejs-mobile` 的 **Node 24 `v24.20.0-0`（lite）**，
  下载页 `https://github.com/digidem/nodejs-mobile/releases/tag/v24.20.0-0`
  （**不要用官方 NodeMobile 的 18.20.4**——iOS 无 JIT 下它没有 WebAssembly，`fetch` 直接是坏的）
- `NodeRuntime.swift` / `BridgeServer.swift` / `BootstrapLoader.swift` / `CatyLog.swift`
- 一个**打桩版 index.js + index.config.js**（先不碰真源，验证链路）
- `Resources/Info.plist` 的全部键（ATS、本地网络、后台音频、相机）
- 一个自检屏（`DiagnosticsView`）：状态 / 端口 / 地址 / Node 版本 / 日志 / 两个 GET 按钮

✅ 验收：App 里显示 `已就绪` + `serverStarted → http://127.0.0.1:xxxxx` + `Node v24.x`，
并且 Swift 侧能 GET 到 `{"ok":true}` 与打桩站点目录。
⛔ 这一步报错概率最高，全是链接和签名问题，把报错原文给我即可。

> **闸门**：这一步做完立刻换**真源**跑一次，记录首屏耗时/内存/是否崩溃。
> 如果无 JIT 下实在慢到不可用，我们立刻转方案（我已在 01 文档里备好两条后路），而不是硬耗。

---

### P3 · 源管理：下载 / 校验 / 缓存（1 天）

🎯 粘贴一个订阅地址，App 能把它下载、MD5 校验、存好，重启 App 不重下。

> ⭐ **这一包的代码也已经写好了**（和 P2 在同一份代码包里，不需要再拖文件）：
> 验收步骤在 **[08-P2操作卡.md 附录 A](08-P2操作卡.md)**。

👉 你要做的：导入一次真源 → 杀掉 App 重开 → 在「诊断」tab 里看日志，然后把
**首屏耗时 / Node 版本 / 是否崩溃** 三个数字发我（D3 的关键产出）。

✅ 验收：导入一次 → 关闭 App → 重开 → 日志显示 **`缓存命中（MD5 一致），不重新下载`**；
多个源能同时存在；同一 bundle 的镜像不会重复下载。
本机可以先在 Windows 上用 `node tools/host/node-host.mjs` 干跑来预览这段逻辑（已实现并验证过）。

---

### P4 · 站点目录 + 能播（2–3 天）· **第一个完整闭环**

🎯 首页出现站点和分类 → 点进去有列表 → 点开详情 → 能播出画面。

👉 你要做的：粘贴 `Sources/Compat/` 与 `Sources/Player/` 下的文件（外加一个很简的列表界面），跑，然后**试播第一个视频**，告诉我现象。

✅ 验收：能播出一个 m3u8 或 mp4 的画面。
⛔ 黑屏但有声音 → 编码不支持（AVPlayer 只认 H.264/H.265+AAC），记录下来，P6 再上 libmpv。
⛔ 一直转圈 → 需要 Referer/UA（防盗链），把该条目的字串给我，我加代理转发。

**到这里，A 方案（能播）就完成了：5–8 个工作日。**

---

### P5 · 界面成型（5–7 天）

🎯 按 [02-ui-spec.md](02-ui-spec.md) 与两张设计稿把 8 个屏做出来。

👉 你要做的：按我给的顺序粘文件，每做完 2 个屏编译一次。
顺序：**源管理+导入引导 → 首页 → 分类 → 详情 → 播放 → 搜索 → 片库 → 设置**。

✅ 验收：对照 `design/ui-mockup.png` 逐屏比对，不一致的地方截图给我。

---

### P6 · 打磨与自签（2–3 天）

🎯 稳定、能长期用、会自己续签。

👉 你要做的：
1. 我给的**续签 SOP** 走一遍（免费账号：每 7 天重装/自动续签；付费账号：1 年）。
2. 按 `Actions` 配置出包（如果你以后没有 Mac 了也能构建）。

✅ 验收：连续 3 天当日常播放器用，没有必须重装才能恢复的问题。

---

## 5. 完整文件清单（我按这个逐个给你）

```
Catys/
├── Caty.xcodeproj                        Xcode 工程
├── Sources/
│   ├── App/
│   │   ├── CatyApp.swift                 入口、启动预热 Node、依赖注入
│   │   ├── RootView.swift                5 个 tab 的骨架
│   │   └── Theme.swift                   设计 token（颜色/间距/圆角/字体）
│   ├── Runtime/                          ★ 最核心，整个 App 的价值所在
│   │   ├── SourceRecord.swift            源记录：URL / MD5 / 镜像 / 状态 / 上次更新
│   │   ├── BundleStore.swift             下载 → MD5 校验 → staging → 原子提交 → 缓存复用
│   │   ├── NodeRuntime.swift             node_start 生命周期、崩溃退避重启
│   │   ├── BridgeServer.swift            NWListener 实现 /msg 桥 + X-CatVod-Token 校验
│   │   ├── RuntimeCoordinator.swift      多源编排、端口登记、健康检查
│   │   └── BootstrapLoader.swift         把 bootstrap.js 从 App 资源落到沙箱并校验
│   ├── Compat/                           ★ TVBox 兼容层（协议翻译）
│   │   ├── VodModels.swift               Site / VodItem / Episode / PlaySource
│   │   ├── NodeRoute.swift               node: 路由拼接（等价 NodeRoute.java）
│   │   ├── SiteMapper.swift              /config → 站点目录（等价 NodeConfigMapper.java）
│   │   ├── PlayUrlParser.swift           $$$ / # / $ 解析 + 全角反向兼容
│   │   └── AggregatorService.swift       多源并发搜索、去重、超时降级
│   ├── Player/
│   │   ├── PlayerEngine.swift            播放器抽象（先 AVPlayer，后 libmpv）
│   │   ├── AVPlayerEngine.swift
│   │   └── PlayerViewModel.swift         进度记忆、换线路、倍速、弹幕开关
│   ├── Store/
│   │   ├── DB.swift                      GRDB 初始化与迁移
│   │   ├── Favorite.swift / History.swift / SearchHistory.swift
│   │   └── KeychainStore.swift           凭据入 Keychain，不落明文
│   ├── Features/                         每个屏一个 folder（View + ViewModel）
│   │   ├── Home/  Browse/  Search/  Detail/  Playback/  Library/
│   │   └── Settings/  ← 含 SourceManageView / ImportSourceView / WebPanelView / DiagnosticsView
│   └── UI/                               组件库（见 02 文档第 5 节）
│       ├── PosterCard.swift / PosterImage.swift / SectionHeader.swift
│       ├── ChipRow.swift / StateView.swift / SkeletonRow.swift
│       └── GlassToolbar.swift / EpisodeGrid.swift / SourceBadge.swift
├── Resources/
│   ├── bootstrap.js                      ← 直接复制 tools/host/bootstrap.js（已写好）
│   ├── Assets.xcassets
│   └── Info.plist
└── Frameworks/
    └── NodeMobile.xcframework            Node.js 运行时（iOS 版）
```

约 **45 个文件**，全部由我产出，你只负责放进工程。**你不需要读懂任何一个文件。**

---

## 6. 关键配置（我配置，你核对）

### 6.1 `Info.plist` 必加键（少一个就会出各种玄学问题）

```xml
<!-- 源站大量是 http，且要用本机回环服务 -->
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsArbitraryLoads</key><true/>
  <key>NSAllowsLocalNetworking</key><true/>
</dict>

<!-- iOS 14+ 访问本机/局域网需声明 -->
<key>NSLocalNetworkUsageDescription</key>
<string>需要访问本机运行时（127.0.0.1）以加载你导入的源</string>

<!-- 后台播放声音 -->
<key>UIBackgroundModes</key>
<array><string>audio</string></array>

<!-- 可选：扫码导入源 -->
<key>NSCameraUsageDescription</key>
<string>用于扫描源二维码</string>
```

### 6.2 Node 运行时的两个关键点

1. **编译缓存必须在 M1 就开**（`bootstrap.js` 里已写好，别删）：
   ```js
   // 把"每次启动都解析几 MB JS"变成"只有第一次解析"
   require('node:module').enableCompileCache?.(path.join(dataRoot, '.compile-cache'))
   ```
   **在 iOS 无 JIT 环境下，这是最值钱的一笔优化**。Node ≥ 22.1 才有（函数名要 ≥ 22.8）。
   运行时的选型已定：**Node 24（`digidem/nodejs-mobile` v24.20.0-0）**，两件事都满足。

   > ⚠️ **iOS 上还有一个必须一起开的开关**：`NODE_COMPILE_CACHE_PORTABLE=1`。
   > 编译缓存默认按**绝对路径**做 key，而 iOS 容器路径含 UUID、重装/更新后会变 →
   > 不加这个开关，缓存会**静默全部失效**（你会以为优化开了，其实每次都在重新解析）。
   > App 侧已用 Swift 在 `node_start` 之前 `setenv` 设好（`NodeRuntime.swift`），
   > 环境变量必须早于 Node 启动才生效，所以不要在 JS 里设。

2. **`catServerFactory` 必须把监听强制到 `127.0.0.1` + 随机端口**（不要写死端口，避免和其他 App 冲突）。

### 6.3 命令行编译（不打开 Xcode 也能构建）

```bash
xcodebuild -project Caty.xcodeproj -scheme Caty -configuration Debug \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

出未签名 ipa（给手机端签名工具用）：
```bash
xcodebuild -project Caty.xcodeproj -scheme Caty -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
mkdir -p Payload && cp -R build/Release-iphoneos/Caty.app Payload/ && zip -qr Caty-unsigned.ipa Payload
```

---

## 7. 报错速查表（小白最常撞的 20 条）

| # | 现象/报错 | 原因 | 怎么办 |
|---|---|---|---|
| 1 | `Untrusted Developer` | 证书没被信任 | 手机 `设置 › 通用 › VPN 与设备管理 › 开发者 App` → 信任 |
| 2 | `Unable to install ... not signed correctly` | 签名失败/证书过期 | 重新 Run 一次；免费账号 7 天会过期 |
| 3 | `The certificate ... has expired` | 7 天到了 | 重新连 Mac Run 一次即可（数据不丢） |
| 4 | `No account with a valid signing certificate` | Xcode 没登录 Apple ID | `Xcode › Settings › Accounts` 登录 |
| 5 | `process launch failed: not able to launch` | 开发者模式没开 | 手机 `设置 › 隐私与安全性 › 开发者模式` 打开并重启 |
| 6 | `This app can't be installed because ... maximum number of apps` | 免费账号限制 | 删掉别的自签 App（免费账号通常同时最多 3 个） |
| 7 | `Library not loaded: @rpath/NodeMobile.framework/...` | framework 没嵌入 | 把 NodeMobile 加到 target 的 **Frameworks, Libraries, and Embedded Content**，选 **Embed & Sign** |
| 8 | `Undefined symbol: _node_start` | 没链接 NodeMobile | 同上：先 **Link**（Libraries 里出现），再 Embed |
| 9 | `Building for 'iOS', but linking in object file built for 'iOS Simulator'` | 选了模拟器架构 | 目标改成"真机"，或确认用的是 `ios-arm64` 那一片 |
| 10 | `dyld: Symbol not found` 且 App 一启动就闪退 | framework 没嵌入/签名不对 | 检查 Embed & Sign；清 `DerivedData` 重编 |
| 11 | 模拟器能跑，真机不行 / 反之 | 架构不同 | 真机验证只认真机结果；模拟器结论作废 |
| 12 | 一直白屏，骨架不消失 | `/config` 没返回 | 看 `DiagnosticsView` 的日志；贴给我 |
| 13 | 提示"本地网络"权限弹窗 | 正常 | 点允许 |
| 14 | 请求失败 `A server with the specified hostname could not be found` | 域名被墙/DNS | 换镜像源；或我给你加 DoH |
| 15 | 视频黑屏但有声音 | 编码不支持（AVPlayer 只认 H.264/H.265+AAC） | 记录该片源，P6 上 libmpv |
| 16 | 一直转圈不播 | 防盗链缺 Referer/UA | 把条目给我，走 bundle 的 `/proxy` 转发 |
| 17 | App 用一会儿被杀 | Node 内存高（尤其抓大目录） | 诊断页看内存；我加限制与自动重启 |
| 18 | Xcode 卡住/索引不动 | DerivedData 太大 | 删 `~/Library/Developer/Xcode/DerivedData` 后重开 |
| 19 | `Command CodeSign failed` | 钥匙串有旧证书 | Xcode › Settings › Accounts › Manage Certificates 清理 |
| 20 | 切到后台再回来就不播了 | 后台被挂起 | 已配 `UIBackgroundModes=audio` + 回前台重启逻辑，若仍不行贴日志 |

**P2 起新增（Node 运行时 / Node 24 特有）**

| # | 现象/报错 | 原因 | 怎么办 |
|---|---|---|---|
| 21 | 日志里 `WebAssembly=undefined`，`fetch` 不可用 | 用了官方 NodeMobile 的 **Node 18.20.4** | 换 `digidem/nodejs-mobile` 的 `v24.20.0-0`（见 [08-P2操作卡](08-P2操作卡.md)） |
| 22 | App 启动一秒内闪退，日志有 `FatalProcessOutOfMemory` / `VirtualMemoryCage` | V8 指针压缩 cage 要一次性映射近 8 GB 虚拟地址，iOS 给不了（受限 entitlement 自签拿不到） | 贴原文给我，我换构建参数/换构建版本 |
| 23 | 状态一直「启动中」，日志一行 Node 输出都没有 | NodeMobile 没真正跑起来（没 Embed / 没设桥接头） | 确认 `Embed & Sign`；确认 `SWIFT_OBJC_BRIDGING_HEADER` 已设 |
| 24 | 编译报 `Cannot find 'node_start' in scope` | 桥接头或链接缺失 | 同 23；`Undefined symbol: _node_start` 则是只 Link 没 Embed |
| 25 | 编译报 `multiple 'main'` / 并发 `Sendable` 错误 | Xcode 自动生成的 `CatyApp.swift` 没删 / Swift 6 严格并发 | 删掉自动生成的 App 文件；Swift Language 选 **Swift 5**，Strict Concurrency 选 **Minimal** |
| 26 | 想重启 Node 但没按钮 | 正常：iOS 上一个进程只能起一次 Node（`node_start` 不可重入） | 杀掉 App 重新打开；这也是为什么状态机里的"自动退避重启"在 iOS 上要改成"进程级重启" |

**通用原则**：报错 → **把原文整段贴给我**（不要自己翻译或概括）→ 我给修复包。

---

## 8. 验收测试清单（每轮功能做完跑一遍）

| 类别 | 用例 | 期望 |
|---|---|---|
| 源 | 导入一个新源 | 显示下载体积、MD5 校验通过、出现站点 |
| 源 | 杀进程重开 | 日志显示缓存命中，不重新下载 6–9 MB |
| 源 | 换镜像地址（MD5 相同） | 不重新下载，只更新记录 |
| 源 | 源站改动了内容 | 自动拉新版并原子切换，旧版可回滚 |
| 源 | 删除源 | 数据目录一并清空 |
| 浏览 | 首页 | 有内容；运行时未就绪时显示骨架+缓存内容，不是白屏 |
| 浏览 | 分类翻页 | 滑到底自动加载下一页，不重复不跳号 |
| 搜索 | 关键词搜索 | 多源并发；某个源超时不影响其它源出结果 |
| 详情 | 选集 | 线路切换后集号对应正确 |
| 播放 | 播放/暂停/拖动/倍速/下一集 | 正常 |
| 播放 | 退出后再进入 | 从上次进度继续 |
| 播放 | 后台播放与回前台 | 声音继续 |
| 异常 | 飞行模式 | 顶部显示"已离线·显示缓存内容"，不崩 |
| 异常 | 杀掉 Node 运行时 | 自动重启并恢复，或给出明确提示 |
| 数据 | 收藏/历史 | 重启后仍在 |

---

## 9. 术语表（不懂就查这里）

| 词 | 含义 |
|---|---|
| **源 / 通用接口 / 猫源** | 一个 `index.js.md5` 地址。它不是配置，而是**一整个 Node 小程序** |
| **bundle** | 就是那个 `index.js`（6–9 MB），本项目的核心处理对象 |
| **契约 A / 契约 B** | 源与 App 的对接方式。实测你的 4 个源**全是契约 B**（需要 bootstrap 与 /msg 桥） |
| **`/msg` 桥** | 源启动后回调 App 的通道，用 `X-CatVod-Token` 鉴权 |
| **TVBox / CatVod / 猫爪(CatPaw)** | 这个生态的名字。格式互相兼容，所以叫"通用接口" |
| **站点 (site)** | 源里提供内容的一个入口，有 `key` 和路由 `/spider/<key>/3` |
| **`vod_play_from` / `vod_play_url`** | 播放源名（`$$$` 分隔）与播放地址串（`#` 分集、`$` 分"集名/地址"） |
| **自签 (sideload)** | 不用 App Store，用你自己的 Apple ID 给 App 签名后装到手机 |
| **7 天续签** | 免费 Apple ID 签名的 App 只有 7 天有效期，到期要连电脑重装一次 |
| **TrollStore** | 永久签名的工具，只支持 iOS 14.0–16.6.1 / 17.0 部分 → **你的 iOS 27 用不了** |
| **JIT** | 即时编译，能让 JS 快很多。iOS 默认禁止 → 我们的优化重点就是绕开它（编译缓存 + 预热） |
| **ATS** | iOS 的网络安全策略，默认禁止 http；自签自用我们直接放开 |
| **NodeMobile** | 把 Node.js 塞进 iOS App 的那个库（我们的运行时来源） |
| **libmpv / VLCKit** | 比系统播放器更强的播放内核，支持 mkv/字幕/软解（P6 才需要） |

---

## 10. 成本与法律

**成本**：Mac（借用 0 / 二手 2500–3500 / 云 100–300 月）+ 可选 $99 年费账号 + 你的时间。
除此之外**没有任何要花钱的地方**，源是你自己的订阅。

**法律边界（重申一次，很重要）**：
- Caty **只是一个容器**：不含任何内容、不内置任何源、不提供 VIP 解析或 DRM 绕过。
- 请保持 **自签自用**：不要公开分发、不要上架、不要收费。
- 源是**第三方程序**，运行它等于允许它访问本机文件与网络，并可能保存你的网盘凭据 —— 只用你信任的源，别用主力账号。

---

## 11. 本次补齐的缺口清单

之前几轮的文档只到"架构 + 计划 + 界面规格"，对小白来说还缺这些东西，**现在已经全部补上**：

| 之前缺的 | 现在在哪 |
|---|---|
| ❗ iOS 环境从零搭建步骤（Xcode/账号/开发者模式/信任证书） | 本文第 4 节 P0–P1 |
| ❗ 先跑通签名再写功能的顺序 | 本文 P1（并解释了为什么） |
| ❗ 完整文件清单（45 个文件各自职责） | 本文第 5 节 |
| ❗ Info.plist / ATS / 后台音频 / 本地网络 权限清单 | 本文第 6.1 节 |
| ❗ 无 JIT 的核心优化（编译缓存） | 本文第 6.2 节 + 已写进 `tools/host/bootstrap.js` |
| ❗ 命令行编译与出 ipa | 本文第 6.3 节 |
| ❗ 报错速查表 | 本文第 7 节（20 条） |
| ❗ 验收测试清单 | 本文第 8 节 |
| ❗ 术语表 | 本文第 9 节 |
| ❗ 三条可选时间线（能播 / 日常可用 / 全功能） | 本文第 1 节 |
| ❗ UI 版式与设计稿 | [02-ui-spec.md](02-ui-spec.md) + `design/*.png` |
| ❗ UI 细节（动效 token / 手势矩阵 / 浅色模式 / 弹幕规格 / 提示文案 / 设置项全表 / 冷启动降级） | 02 文档**第二部分 §11–19** |
| ❗ 数据模型 / SQLite 表结构 / 多源状态机 / 错误码表 / 日志规范 / 设置键表 | [05-data-model.md](05-data-model.md) |
| ❗ 对话与决策记录 | [04-conversation-log.md](04-conversation-log.md) |

**仍然只能由你完成、我无法替代的三件事**（这不是推脱，是物理限制）：
1. 准备一台 Mac
2. 在 Mac/iPhone 上点按钮、装 App
3. 把报错原文贴回来
