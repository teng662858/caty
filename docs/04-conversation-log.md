# Caty 项目对话与决策记录

> 这是**结构化记录**（不是逐字转录）：把项目从零到现在的每一轮问答、实测数据、结论与决策整理成可复查的形式。
> 密码等敏感信息已抹除（写成 `***`）；完整订阅地址请从你自己的聊天记录里取。
> 日期：2026-10-09

---

## 阅读顺序（等会儿开始做 App 时照这个来）

1. **[03-beginner-handbook.md](03-beginner-handbook.md)** ← 从这里开始。你的操作手册，P0→P6 一步步做。
2. [01-dev-plan.md](01-dev-plan.md) —— 大局与里程碑，想知道"为什么这样排"时看。
3. [00-protocol-spec.md](00-protocol-spec.md) —— 技术真相（源到底是什么），想知道"原理"时看。
4. [02-ui-spec.md](02-ui-spec.md) + `design/*.png` —— 界面长相，做 UI 那几天看。

---

## 第 1 轮 · 需求与协议逆向

**你的问题**：想写一个 iPhone 自签自用的软件，核心功能是"通用接口"（MiraPlay / UZN / 羊壳 / 猫影视 / 猫爪 均可用），
兼容 `http://<user>:***@cat.xn--4kq62z5rby2qupq9ub.top/index.js.md5` 这种源接口，要一份详细的开发大纲和步骤计划，
并问"第一步做什么、第二步做什么"。

### 我做了什么

1. **实际抓取该订阅**（只读，带 Basic Auth）：
   | 文件 | 实测结果 |
   |---|---|
   | `index.js.md5` | 200，32 字节，`e5b9b774af06f3014f4cf0087cdf07a9` |
   | `index.js` | 302 → `oss4liview.moji.com/…jpg`，实得 **6,486,569 字节 JS**，`Content-Type: image/jpeg`（伪装），ETag 恰好等于那个 MD5 |
   | `index.config.js` | 9,809 字节，同样是伪装成 JPEG 的 JS，MD5 `93f807174a…`（校验一致） |
   | 根路径 | 200 `"你好！"`；`/config.json` `/sites` 都是 nginx 404 → **该站只是静态分发站** |
   | 域名 | punycode 解码 = `cat.王二小放牛娃.top` |

2. **静态拆包**：这个 6.2 MB 的包是 **esbuild 打包的完整 Node.js 服务端程序**，内含
   `fastify` / `protobufjs` / `pako` / `fs-extra`，用到 27 个 Node 内置模块（`crypto` 40 处、`util`、`stream`、`http`、`fs`…）。
3. **在 GitHub 上找到这套机制的权威出处**（用代码搜索定位标记字符串）：
   - **FongMi/TV 系的 "Node 内置源"（NodeBundle）**：`nodejs/src/main/assets/nodejs/bootstrap.js`、
     `NodeBundle.java` / `NodeService.java` / `NodeRoute.java` / `NodeConfigMapper.java` / `tools/sign-bundle.mjs`，
     并带 `libnode.so`（arm64-v8a / armeabi-v7a）
   - **OKVideoMac**（`yaolin-dev/OKVideoMac`，Swift/SwiftUI，GPL-3.0）：`NodeBundleRuntimeService.swift`、
     `NodeRuntimeContract.swift`、`CatPawProtocol.swift`
   - **JackLeeo/tvbox_flutter** 的 `ios/Runner/NodeJSManager.m`：iOS 侧用 `NodeMobile.xcframework` + GCDWebServer
4. **确认这是唯一的"通用接口"生态**：`xymn2023/catbox` 等源的 README 里，"一键订阅"地址就是 `index.js.md5`，
   并注明适用于 MiraPlay / JSTV / PeekPili / 魔力云播 / 蚂蚁影视 / 猫爪。

### 结论（第一版）

**这类"源"不是配置，而是一整个 Node.js 服务端程序。** App 的本质是
`Node 运行时宿主（>50% 工作量） + TVBox 兼容层 + 播放器/UI`。

启动契约（引用实现原文比对得出）：
```
node <bootstrap.js> <index.js> <index.config.js> <dataRoot> <bridgePort> <token>
bootstrap 必须：注入 catServerFactory / catDartServerPort；patch http.request 自动带 X-CatVod-Token；
              设 CATVOD_DISABLE_AUTOSTART/HOST/PORT/HOME；server.listen 强制 127.0.0.1+随机端口
bundle 必须：  export default { async start(config) }
bundle 回报：  POST /msg {action:'serverStarted', opt:{address:'http://127.0.0.1:PORT', ...}}
客户端：       GET /config → video.sites[] → 映射成 {type:3, api:"node:/spider/<key>/<type>"}
```

### 本轮交付物

- `docs/00-protocol-spec.md`（协议实测规格）
- `docs/01-dev-plan.md`（开发大纲与步骤计划）
- `tools/probe/config-probe.mjs`（安全静态探测，不执行 JS）
- `tools/host/node-host.mjs` + `tools/host/bootstrap.js`（桌面参考宿主，干跑验证通过）
- `README.md`、`.gitignore`

---

## 第 2 轮 · 你又给了三个源，做交叉验证

**你的输入**：
1. `https://9280.kstore.vip/cat/index.js.md5`
2. `https://ghfast.top/https://raw.githubusercontent.com/Darklessing/catvod/refs/heads/main/lmentor/index.js.md5`
3. `https://<user>:***@catpaw.douer.me/index.js.md5`

### 实测对比（四个源）

| 源 | bundle MD5 | 体积 | 契约 | 提供者 | 静态站点数 | 内置模块 |
|---|---|---|---|---|---|---|
| `cat.王二小放牛娃.top` | `e5b9b774af…` | 6,486,569 B | contract-b | 24 | 0 | 27 |
| `9280.kstore.vip/cat` | `e5b9b774af…` | 6,486,569 B | contract-b | 24 | 0 | 27 |
| `ghfast…/Darklessing/catvod/lmentor` | `f320a9caef…` | 9,690,083 B | contract-b | 32 | 0 | 33 |
| `catpaw.douer.me` | `3ecc396404…` | 6,148,459 B | contract-b | 1 | 0 | 29 |

### 四个发现

1. **前两个是同一份 bundle 的两个门面**（MD5、大小、配置 MD5 全同；一个走 302+伪装 JPEG，一个直连诚实报 `text/javascript`）。
   → **源的身份是 bundle MD5，不是 URL。**
2. **四个源全部是 contract-b**（三个标记 `catServerFactory` / `catDartServerPort` / `DEV_HTTP_PORT` 全齐）
   → 宿主契约唯一，`bootstrap.js` 实现一次就够。
3. **9.2 MB 的那个是"全功能版"**，配置里多了 `live` 直播、`emby`（2 台）、`cms` 采集、`t4`、`pansou` 盘搜、
   `webdav`（3 个）、`danmu` + `danmuBuiltin`、`bilibili`、`alist_tvbox`，网盘多了 `pikpak`/`tianyi`/`pan123`；
   而且它**公开托管在 GitHub 上**（`raw.githubusercontent.com` 实测可直连）。
4. **`catpaw.douer.me` 是"容器版"**：配置里没有提供者注册表，只有
   `customSpiders{enabled,dir,urls,strict,allowOverride,factoryTimeoutMs,urlTimeoutMs}`（默认 `urls: []`）
   → 它**远程拉取并执行二级 JS spider**；再加上全功能版的 `danmuBuiltin{host,port,token,autoStart}`
   → **bundle 会另起本地服务，端口不止一个**。这两点必须写进安全设计。

### 四个源共同的硬事实

- `sites.list` **全部为空** → **站点目录只能从运行时的 `/config` 拿**，静态解析配置拿不到。
- 配置 schema 跨版本演化（24 → 32 提供者 → 只剩 customSpiders）→ **宿主不得硬编码 schema**。

### 本轮交付物（更新）

- 探测工具新增三项能力并在四源上验证：**宿主契约判别**、**导出形态检测**、**运行时依赖画像**
- `docs/00-protocol-spec.md` 新增 §8 多源家族对比、§9 验证状态
- `docs/01-dev-plan.md`：M2 改为"缓存按 bundle MD5 + 镜像表"；M6 降级为"先实测源已覆盖多少"；风险表新增第 11 条

---

## 第 3 轮 · UI 结构与版式

**你的问题**：UI 结构/版块排版全设计好了吗？要适配最新、高级清爽的 UI，iPhone 用。

### 我做了什么

之前只到"界面清单"，没有信息架构与排版 —— 这轮补上，并且**直接渲染成图**：
用 HTML+CSS 画出 390×844 的真实尺寸版面，再用本机 Chrome 无头截图出稿。

- `design/ui-mockup.png` —— ①首页 ②分类 ③详情 ④播放 ⑤设置（3392×1536）
- `design/ui-mockup-2.png` —— ⑥聚合搜索 ⑦片库 ⑧首次导入源（2080×1536）
- `design/ui-mockup.html` / `ui-mockup-2.html` —— 可编辑源码，改 CSS 变量即可换配色后重新出稿

### 设计决策

| 决策 | 理由 |
|---|---|
| 玻璃只用于**浮层**（tab bar、导航按钮、播放控制、弹窗） | 海报压在玻璃上会"脏"，这是 Liquid Glass 最常被用错的地方 |
| 强调色取**源配置自带的 `color` 调色板**（默认 `#8CDA60`） | 不用我拍脑袋选色；还能随源切换换皮肤 |
| 海报占位用 **`vod_id` 做种子的渐变** | 同一部片每次颜色一致，滚动不闪色 |
| **首屏永不空白**：Node 未就绪时显示骨架 + 缓存内容 | 无 JIT 环境启动慢，绝不能白屏等 |
| 详情页先用列表已有数据渲染，再异步补全 | 同上 |
| 5 个 tab：首页 / 分类 / 搜索 / 片库 / 设置 | 播放路径 ≤ 3 次点击 |
| 动效克制（zoom 转场 + hero 滚动淡入） | 滚动区大量玻璃/动效会掉帧 |

### 诚实说明

iOS 27 SDK 的具体新增 API 我**不臆测**。设计全部基于 iOS 18/26 一代已稳定的写法
（`TabView`+`Tab`、`NavigationStack`、`LazyVGrid`、`.glassEffect`、`.tabBarMinimizeBehavior`、
`matchedTransitionSource`），到你 Mac 上按实际 SDK 校准即可，不会返工。

### 本轮交付物

- `docs/02-ui-spec.md`（token、信息架构、8 屏版面规格、12 个组件、**界面↔协议字段对照表**、五态矩阵、SwiftUI 要点、UI 构建顺序）
- `design/ui-mockup.png`、`design/ui-mockup-2.png` + 两份 HTML 源码

---

## 第 4 轮 · 工期质疑 + 建 Caty 项目

**你的问题**：只做 iPhone 支持也需要那么久吗？我是小白，做 App 全靠你，请全方位检查并补上缺的东西，
然后把这一页对话放到 Caty 项目里，等会儿开始做。

### 回答（工期）

**只做 iPhone 大约只省 1–2 天** —— 时间不在 iPhone/iPad 的差异上，而在：
macOS 环境搭建、**首次真机签名部署**、**iOS 上跑通 Node 运行时**、**真机反复验证的往返次数**、界面打磨。

给你三条可选时间线：

| 目标 | 工期 | 内容 |
|---|---|---|
| **A 能播** | **5–8 个工作日** | 导入源 → 文字列表 → 能播出画面（丑但能用） |
| **B 日常可用**（推荐） | **约 3 周** | A + 完整 8 屏界面 + 搜索/收藏/历史 + 源管理 |
| **C 全功能** | **6–8 周** | B + libmpv 硬解/字幕/弹幕渲染 + 直播 EPG + WebDAV + iPad |

**唯一硬门槛：你必须有一台 Mac。** 这不是时间问题，是能不能开工的问题。

### 补齐的缺口

见 [03-beginner-handbook.md](03-beginner-handbook.md) 第 11 节。核心是这几样：
iOS 环境从零搭建步骤（含开发者模式/信任证书）、**先跑通签名再写功能**的顺序、45 个文件的完整清单、
Info.plist/权限清单、**无 JIT 的关键优化（编译缓存）**、命令行编译与出 ipa、**20 条报错速查表**、
验收测试清单、术语表、分工表（你只做三件事）。

### 项目改名

项目根目录最终定在 **`D:\Zcode\Catys`**（App 产品名仍叫 Caty）—— 所有文档、设计稿、工具都在里面。
（最早叫 `catnode-ios`，中间曾短暂改名为 `Caty`，最后按你的要求落到 `D:\Zcode\Catys`。）

---

## 第 5 轮 · P2/P3 代码包与运行时选型（2026-10-09）

**触发**：你说"继续带我开发"；而 `docs/07-冲刺计划.md` 里写明了最快路径 ——
**Mac 还没到位时，先把 P2 + P3 的代码写完**，等 Mac 一到直接编译，省 1–2 天。

### 我做了什么

1. **派了一轮专门调研**（查证 + 交叉验证，不是凭记忆）：把"iOS 上到底该用哪个 Node 运行时"钉死。
2. **写了 P2 代码包**（`ios/`，12 个文件里的前 7 个）：`NodeRuntime`（node_start 生命周期 + 看门狗 +
   采集 Node 的 console 输出）、`BridgeServer`（Network.framework 实现 `/msg` 桥 + `/health`，
   只绑 127.0.0.1）、`BootstrapLoader`（把 bootstrap.js/打桩 bundle 落到沙箱 + sha256 比对）、
   `CatyLog`（环形 2000 条 + 磁盘滚动 5×2MB + **自动脱敏**）、打桩 bundle、自检屏、完整 `Info.plist`、桥接头。
3. **桌面预演通过**：`node tools/host/p2-selftest.mjs` → `✓ P2 链路自检通过`
   （同一份 `bootstrap.js` + 打桩 bundle，跑通 `node_start → catServerFactory → serverStarted → /config → 站点映射`）。
   这一步的意义：**上 Mac 之前就把协议链路排除了故障**，真机上出问题基本只剩"链接/签名"两类。
4. **写了 P3 代码包**：`BundleStore`（流式限量下载 / 拒绝 HTTPS→HTTP 降级 / MD5 校验 / staging 原子提交 /
   缓存命中 / **镜像复用**：同 MD5 直接复制不重下 / 契约判别）、`SourceRecord`+`SourceStore`、
   `RuntimeCoordinator`、`KeychainStore`、源管理界面。
5. **加了 `tools/check-swift-heuristics.mjs`**：Windows 上没有 Swift 编译器，用它先排除括号/引号/冲突标记
   这类低级错误（明确不是编译替代品）。

### 关键发现（已写进 AGENTS.md 事实 11–13，别重新推导）

| 发现 | 影响 |
|---|---|
| 官方 `nodejs-mobile` 停在 **Node 18.20.4**，基本停维护 | 不能用它 |
| iOS 无 JIT 时 V8 **没有 WebAssembly**；而 Node 的 `fetch()`（undici）依赖 wasm 版 llhttp | **Node 18 在 iOS 上 `fetch` 直接是坏的**，源里到处在用 → 只能上 Node 24 线（把 polywasm 编进运行时） |
| `digidem/nodejs-mobile` 的 `v24.20.0-0` 有稳定 release + 第三方真机验证（comapeo 从 18.20.4 升到 24.19 并过真机 smoke） | **选它**（lite 版更省内存） |
| 编译缓存默认按**绝对路径**做 key，而 iOS 容器路径含 UUID | 必须 `NODE_COMPILE_CACHE_PORTABLE=1`，否则静默全 miss |
| `NODE_COMPILE_CACHE` 只在 Environment 创建时读一次 | 必须宿主在 `node_start` **之前** `setenv` |
| `node_start` **不可重入**、无 `child_process` | iOS 上"重启 Node"= 重启 App |
| V8 指针压缩 cage 要一次性 mmap 近 8 GB，iOS 地址空间上限约 7.375 GB（受限 entitlement 自签拿不到） | 已知风险：真机若在启动一秒内 `FatalProcessOutOfMemory` 就是它 → 备选是关指针压缩的构建 |
| `FongMi/TV` **没有 iOS 版**（其 nodejs 模块在别人 fork 里） | 纠正了 AGENTS 事实 #10；iOS 侧改看 **`1970905901/Y-Player`**（Swift 的 `CatVodNode`，同域最值得照抄） |

### 本轮交付物

- `ios/`：P2 + P3 全部源码（12 个文件，约 2100 行）+ 打桩 bundle + `Info.plist` + 桥接头
- `docs/08-P2操作卡.md`：NodeMobile 下载与逐步点击说明（含 P3 验收）
- `tools/host/p2-selftest.mjs`、`tools/check-swift-heuristics.mjs`
- 手册更新：P2 段重写、新增 6 条报错速查（21–26）、6.2 节补 portable 要点

---

## 第 6 轮 · 零 Mac 通路 + P4（2026-10-09）

**触发**：你说"我还没有 Mac，先从不需要编译的步骤开始，以最快的速度把 APP 做好"。

### 我做了什么

1. **把运行时从"调研结论"变成"实证"**：直接下载了 `digidem` 的 lite 包并扫描二进制 ——
   包内 Node **v24.20.0**、含 **polywasm** 与 `UNDICI_NO_WASM_SIMD`、Mach-O arm64 **动态库**、
   `MinimumOSVersion 14.0`、Xcode 26 构建；sha256 记进 AGENTS 事实 11。
   （顺带发现：**模拟器片只有 arm64**，Intel Mac 跑不了模拟器；国内直连 GitHub release 只有 16 KB/s，
   `gh-proxy.com` 能到 ~1 MB/s。）
2. **搭出"零 Mac"编译安装通路**（这是本轮的真正价值）：
   - `ios/project.yml`（XcodeGen 描述）—— 因为没 Mac 就生成不了 `.xcodeproj`，交给 runner 现场生成；
   - `.github/workflows/ios.yml` —— 借 GitHub 的 macOS 机器：下载 NodeMobile（**校验 sha256**）→ 生成工程 →
     `xcodebuild CODE_SIGNING_ALLOWED=NO` → 打包 `Caty-unsigned.ipa` → 作为 Artifact 下载；
   - `docs/09-没有Mac也能装到手机.md` —— 从注册 GitHub 到 **Sideloadly 签名装机**、7 天续签、专属报错表。
3. **交付 P4 代码包**：Compat 层（`VodModels` / `NodeRoute` / `SiteMapper` / `PlayUrlParser` / `NodeClient`）
   + `AVPlayerEngine` + 首页/分类列表/详情/播放四屏（粗版）→ **到这里就是"能播"**。
4. **让 P4 在没有真源的情况下就能端到端验证**：给打桩 bundle 补了分类（`class`）与取播放地址（`ac=play`）两条分支，
   详情里故意放两种剧集（直链 / 标识），并用 Apple 官方测试流当片源 ——
   所以在手机上"不导入任何真源"就能把 首页→列表→详情→播放 全走一遍。
5. 桌面预演再次通过（现在覆盖 列表 / 详情 / 取播放地址 / 搜索 四个 endpoint）。

### 本轮决策（ADR 续）

| # | 决策 | 理由 | 备选与代价 |
|---|---|---|---|
| 14 | 编译走 **GitHub Actions（macOS runner）出未签名 ipa + Windows 端 Sideloadly 签名** | 没有 Mac 时唯一免费且可用的编译方式；云 Mac 也一样插不了 USB，还更贵 | 借/买 Mac：迭代快得多，但当下买不到 |
| 15 | 工程文件用 **XcodeGen** 生成，`.xcodeproj` 不进仓库 | 没 Mac 就写不出 pbxproj；让 runner 现场生成，有 Mac 时同一条命令也能用 | 手写 pbxproj：易错且无法本地验证 |
| 16 | **NodeMobile.xcframework 不进仓库**（CI 每次下载 + sha256 校验） | 100 MB+，国内推送会慢到不可接受；CI 从 GitHub 拉 GitHub 是快的 | 提交进仓库：推送几分钟起 |
| 17 | P4 的 endpoint 先按 **TVBox 生态通用约定**（`ac=list/detail/search/play`）实现 | 真源的确切约定还没抓（D0 未做），先按生态惯例把闭环打通；日志会打印每次请求，方便对照 | 等 D0 抓包再写：会拖慢，而 P4 的价值就是闭环 |

---

## 关键决策记录（ADR 简版）

| # | 决策 | 理由 | 备选与代价 |
|---|---|---|---|
| 1 | 运行时用 **NodeMobile.xcframework**（社区 fork） | 唯一成熟路线；FongMi 用 libnode、OKVideoMac 也内嵌 Node.js，生态已验证 | 自己编译 libnode：多 2–3 周，仅在 NodeMobile 不可用时才走 |
| 2 | **不手写 JS 引擎 shim** | 该 bundle 用到 27–33 个 Node 内置模块（含 `crypto` 40 处、`worker_threads`、`async_hooks`、`net`），shim 工作量不现实 | 无 |
| 3 | 缓存按 **bundle MD5** 建条目 + 镜像表 | 同一 bundle 有多个镜像（实测 #0 = #1），换镜像不该重下 6–9 MB | 无 |
| 4 | 配置**静态解析**、绝不 eval | 配置是数据不是代码；引用实现也是这么做的 | 若源改成动态生成配置，需要隔离执行 |
| 5 | 播放器先 **AVPlayer**，后 libmpv | 先打通闭环（HLS/MP4 覆盖大部分），mkv/字幕/软解放 P6 | 直接上 libmpv：+1–2 周，且更早卡在编译上 |
| 6 | 网盘登录用 **WebView 打开源自带的 `/website`** | 源自带 quark/pan189/pan115/new139/thunder/bili 登录与 WebDAV 备份，不必自研 | 自研网盘协议：+2 周且毫无必要 |
| 7 | UI 用 **SwiftUI + Liquid Glass 分层** | 出活快，玻璃只做浮层可保证"高级清爽" | UIKit：更可控但慢 |
| 8 | **无 JIT 是既定前提**（iOS 27 无 TrollStore） | TrollStore 只支持 14.0–16.6.1 / 17.0 部分 | 转"远程后端模式"（把 bundle 部署到 VPS）作为后路 |
| 9 | 运行时定为 **`digidem/nodejs-mobile` v24.20.0-0（lite）** | 官方线 Node 18 在 iOS 上 `fetch` 是坏的、又没有编译缓存；Node 24 线两件事都解决且有真机验证 | 自编 Node（需 Mac + 1–2 天）；`fogtape` 同源 fork（更新但是 prerelease） |
| 10 | 源清单先用 **JSON 文件**（`sources/registry.json`），**GRDB 推迟到 P5** | P3 阶段"少一个依赖 = 少一个报错来源"；收藏/历史/搜索历史到 P5 才需要表结构 | 现在就上 GRDB：多一个 SPM 依赖与失败模式；迁移成本 = 一次性导入 |
| 11 | iOS 上"**自动退避重启**"改为"**进程级重启**"（提示重开 App） | `node_start` 不可重入，进程内起不了第二个 Node | 无（除非改用可停止的运行时） |
| 12 | 多源先"**同一时刻只激活一个源**" | 同上；单实例承载多 bundle 的方案待 M1 真机数据再定（docs/00 §6 原本就这么要求） | 单实例多 bundle：等实测 |
| 13 | `bootstrap.js` 里 `enableCompileCache` 加 `if (!process.env.NODE_COMPILE_CACHE)` 判断 | iOS 由宿主 `setenv`（必须早于 Node 启动），JS 里再开一次没有意义；桌面行为不变 | 无 |

---

## 待办（按顺序）

- [ ] **你**：准备一台 Mac（优先级最高，否则后面全卡住）
- [ ] **你**：Windows 上跑一次真跑，产出 fixture：
      ```bash
      cd /d/Zcode/Catys
      node tools/host/node-host.mjs 'https://ghfast.top/https://raw.githubusercontent.com/Darklessing/catvod/refs/heads/main/lmentor/index.js.md5' --run --probe-routes
      ```
      把 `/config` 和 `/spider/<key>/3` 的响应贴回来 → 我产出 `docs/contract-notes.md`
- [x] **我**：P2 代码包（NodeRuntime / BridgeServer / BootstrapLoader / CatyLog + 打桩 index.js + 自检屏 + Info.plist）
- [x] **我**：P3 代码包（SourceRecord / SourceStore / BundleStore / RuntimeCoordinator / KeychainStore + 源管理界面）
- [ ] **我**：P4 代码包（Compat 层 + AVPlayer 播放器 + 粗列表 UI）
- [ ] **我**：P5 代码包（按 UI 规格逐屏）
- [ ] 你验证 → 贴报错 → 我修 → 循环

---

## 附：本项目已实测通过的东西（不是纸上方案）

| 组件 | 状态 |
|---|---|
| `tools/probe/config-probe.mjs` | ✅ 四源实测通过（MD5 校验、302 跳转、MIME 伪装识别、契约判别、配置静态解析、`--dump` 脱敏） |
| `tools/host/node-host.mjs` | ✅ 干跑通过（下载 / MD5 校验 / staging+原子提交 / 缓存复用 / bridge 起停 / 端口自动分配） |
| `tools/host/bootstrap.js` | ✅ 语法校验通过，实现完整启动契约（含编译缓存优化 + iOS 的 portable 判断） |
| `tools/host/p2-selftest.mjs` | ✅ 通过：桌面预演 P2 全链路（`serverStarted → /config → 站点映射`），用的就是 iOS 那份 bootstrap.js |
| `tools/check-swift-heuristics.mjs` | ✅ 12 个 Swift 文件全部通过（括号平衡 / 引号 / 冲突标记 / CRLF） |
| `ios/`（P2+P3 源码） | ⏳ 待真机编译：Windows 上无法编译 Swift，**上 Mac 第一件事就是 `Cmd+B`** |
| `design/*.png` | ✅ 已渲染并核对（8 个屏） |
| 真源 `--run` 端到端 | ⏳ 等你打开这个开关（会执行第三方代码，所以留给你） |

---

## 第 7 轮 · P5 界面与片库（2026-10-09 深夜）

**触发**：用户说"把 P5 做完再出包，做快点"。

### 交付内容（一次推送，编译通过并出包）

| 模块 | 文件 | 要点 |
|---|---|---|
| 本地库 | `Store/LibraryStore.swift` | 收藏 / 历史（含进度）/ 设置；**JSON 落盘**（不引 GRDB，理由见 ADR 10）；写盘节流 5s |
| 设计 token | `App/Theme.swift` | 主色/圆角/间距/海报比例 + ChipLabel / RemarksBadge |
| 组件 | `UI/PosterCard.swift`、`UI/StateView.swift` | 海报卡片与行、五态、骨架屏 |
| 首页 | `Features/Home/HomeView.swift` | 站点胶囊 + 分类胶囊 + 海报墙 + 翻页 + 骨架屏 |
| 分类 | `Features/Browse/BrowseView.swift` | 分类菜单 + **筛选项**（`filters` → `extend`）+ **目录条目递归** |
| 详情 | `Features/Detail/DetailView.swift` | 头部 + 收藏 + 继续观看 + 线路 + 选集（标记在看）+ 目录入口 |
| 播放 | `Features/Playback/PlayerView.swift` | 进度条 + 断点续播 + 倍速 + 上下集 + 播完自动下一集 |
| 片库 | `Features/Library/LibraryView.swift` | 收藏网格 + 历史列表（进度/相对时间） |
| 设置 | `Features/Settings/SettingsView.swift` | 播放/界面/源/存储/关于，源管理与诊断收进来 |
| 导航 | `App/RootView.swift`、`App/CatyApp.swift` | 4 tab（首页/片库/搜索/设置）；URLCache 500MB/50MB |

### 本轮踩的坑（写进代码注释，避免复发）

1. **SwiftUI 表达式过深 → 类型检查超时**：搜索页连挂两次，最终解法是"拆小块 + 把分组数据预先算成数组 + 用
   `Section(header: Text(...))` 而不是 `Section(计算属性)`"。
2. `ForEach` 要求元素 `Identifiable`（自定义 Hit 结构体要显式加）。
3. 闭包式 API 改签名后要全局搜残留调用（`publish { }` 漏了两处）。

### 已知缺口（留给 P6）

动效与手势、浅色模式、后台音频、libmpv（mkv/字幕/软解）、直播 EPG、弹幕渲染、iPad。

---

## 第 8 轮 · 真机反馈三连（2026-10-11）

**触发**：用户装完第五轮的包，回三句话——「为什么播放器还是这样的」「弹幕很卡」「切换源直接卡死」，附了一张小窗播放页截图。

### 逐条定位（都不是"没装上新包"）

| 反馈 | 根因 | 处理 |
|---|---|---|
| 播放器还是这个样子 | 第五轮的"播放页重做"**只接到了全屏**那一侧（`FullscreenPlayerView`）；竖屏小窗 `PlayerView` 还是 P5 的旧版式：画面钉在顶部一小条、下面一大片空白、按钮挤在滚动区里、进度条藏起来 | 小窗也走 `PlayerControlsOverlay`（新增 `compact` 模式），改成"画面优先"：画面区高度按视频比例算（≥230pt、≤屏幕 58%），画面下方只留 剧名/内核/截图/画中画/选集 |
| 弹幕很卡 | ① `DanmakuOverlay` 每帧都对整集（几万条）`comments.filter` 全表扫一遍；② 文本宽度缓存写在 `@State` 里、在 Canvas 绘制过程中异步回写 → 每帧触发失效重绘（刷屏式重绘）；③ 没有轨道避让，几百条叠着画；④ 缓冲/暂停时还在外推位置 | 二分查找窗口（弹幕按时间升序）+ 宽度缓存搬进带锁的类（不写状态）+ 轨道避让 + 一帧封顶 140 条 + 暂停时停掉时间线 + 位置外推封顶 0.6s |
| 切换源直接卡死 | ① `HomeView.loadSite()` 里 `guard !loading else { return }` —— **正在载入时再点别的站点会被静默丢弃**：标题换了、内容还是旧的、没有任何提示；② 没有"最后一次说了算"，慢的旧请求回来会覆盖新站点；③ `initSite` 只插标记不等结果 → 后台预热和用户点击并发时，home 用**过期的默认域名**去请求（转圈/取不到内容）；④ 一屏封面全走源的 `/imageProxy`，几十张图挤在源那**一个 Node 线程**上（iOS 无 JIT），切站点要等的 home/category 排在它们后面 | ②③④：`loadToken` 世代号（最后点的赢 + 旧结果丢弃）+ 载入条上加「取消」+ 3 秒后提示"第一次打开要慢一点"；`initSite` 改成"同一个 init 只发一次、其它调用者等它"，404（没有 init 路由）记成"不用再 init"；封面把 `/imageProxy?url=…&customHeaders=…` 拆开**直连**（带源给的 Referer/UA），失败再回退到代理 |

### 顺带修的

- `PlayerView.resolve()`：连点"下一集"会并发好几个 `POST /play`（源解析网盘一次好几秒）→ 加世代号，只认最后一次，慢回来的不覆盖画面。
- `RuntimeCoordinator.setSourceEnabled`：取包要几秒，开关上什么都不显示看着像"点了没反应"→ 先写一句"正在取包…"。

### 经验（写给以后的会话）

1. **"重做版式"要核对调用点**：同一个概念有两处视图（小窗 / 全屏）时，改完一处必须 `grep -rn '新组件名' ios/Sources` 确认另一处也接上了，否则用户看到的是"没改"。
2. **每帧跑的东西必须和"总量"无关**：O(总量) × 帧率 = 卡死；绘制路径里**不要写 SwiftUI 状态**（`@State` 的异步回写会造成刷屏式重绘）。
3. **"点了没反应"多半是 `guard ... else { return }` 丢请求**：用户能连点/抢点的地方，一律改成"最后一次说了算 + 世代号丢弃旧结果 + 给取消按钮"。
4. **本地 Node 是单线程**：宿主要把大批量的活（封面图这种）自己扛下来，别把它当 CDN 用；`init` 这类"先决条件"请求要**共享同一个 in-flight 任务**，不能只放一个标记。
