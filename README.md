# Caty —— iPhone 自签「通用源」播放器

> 🤖 **AI 助手请先读 [AGENTS.md](AGENTS.md)**（项目说明、关键技术事实、铁律、当前下一步）。

> **项目位置（Windows）**：`D:\Zcode\Catys`  ·  **App 产品名**：Caty  ·  **目标设备**：你的 iPhone（iOS 27.0.1，自签）

一个自签自用的 iPhone 影视客户端，核心能力是**兼容这一类"通用接口"订阅**
（MiraPlay / UZN / 羊壳 / 猫影视 / 猫爪 / JSTV / PeekPili / 魔力云播 / 蚂蚁影视 等共用同一套格式）：

```
http://<user>:<pass>@<host>/index.js.md5
```

---

## 最重要的一个结论（先读这个）

**这类"源"不是一份规则配置，而是一整个 Node.js 服务端程序**（本次实测：6.2 MB 的 esbuild 产物，
内含 fastify、protobufjs、pako，以及夸克/UC/阿里/百度/115/天翼/123/Telegram/AList 等一整套网盘解析）。

所以目标 App 的本质是：

```
Node 运行时宿主（最核心，工作量 > 50%）  +  TVBox 兼容层（协议翻译）  +  播放器/UI
```

**不是** JS 规则解释器，**也不是** JSON 配置解析器。`index.js.md5` 只是一个"版本标记 + 校验文件"：

```
订阅 URL           → 拆出四件套
index.js.md5       → 32 位 MD5，用来判断要不要重新下载
index.js           → Node 程序，必须 export default { async start(config) }
index.config.js    → 默认配置（静态对象字面量，不执行）
index.config.js.md5→ 配置的 MD5

客户端要做：
  下载 → 校验 → 缓存提交 → 用内置 Node 运行时执行 bootstrap.js
  → bundle 调 globalThis.catServerFactory() 起本地 HTTP 服务并回报端口
  → 客户端 GET http://127.0.0.1:<port>/config 拿站点目录
  → 映射成 TVBox 站点（type:3, api:"node:/spider/<key>/<type>"）→ 播放
```

细节全部在 [docs/00-protocol-spec.md](docs/00-protocol-spec.md)（含实测数据与引用实现出处）。

### 补充：源的身份是 bundle 的 MD5，不是 URL

对 4 个订阅做过对比（见 [00 文档 §8](docs/00-protocol-spec.md)），分成三个家族：

| 家族 | 体积 | 特征 |
|---|---|---|
| **A 基础版** | 6.2 MB / 24 提供者 | 阿里·夸克·UC·百度·115·123资源·光雅·盘链·B站 + 2 台 AList |
| **B 全功能版** | 9.2 MB / 32 提供者 | 多了 `live` 直播、`emby`、`cms` 采集、`t4`、`pansou` 盘搜、`webdav`、`danmu` 弹幕、`pikpak`/`tianyi`/`pan123` |
| **C 容器版** | 5.9 MB | 配置里只有 `customSpiders{dir,urls,…}`，站点靠二级 spider 注入 |

其中 `9280.kstore.vip/cat` 与 `cat.王二小放牛娃.top` 是**同一份 bundle 的逐字节镜像**（MD5、大小、配置全同）。
所以缓存要**按 bundle MD5 建条目**并维护镜像列表，换镜像就不必重下这 6–9 MB。

四个源的 `sites.list` **全部为空** —— 站点目录只能从**运行时**的 `/config` 拿，静态解析配置是拿不到的。

---

## 文档

| 文件 | 说明 |
|---|---|
| [AGENTS.md](AGENTS.md) | **给 AI 助手的项目说明**（新会话自动读取）：项目是什么、用户是小白的分工、环境事实、10 条关键技术事实、7 条铁律、当前下一步 |
| [docs/03-beginner-handbook.md](docs/03-beginner-handbook.md) | **给你的操作手册** ⭐ 从 P0 开始照着做 |

> 👉 **如果你是来开始做 App 的，先看 [docs/03-beginner-handbook.md](docs/03-beginner-handbook.md)** ——
> 那是给你的操作手册（P0→P6 每一步"你点什么、我做什么、怎么验收、卡住怎么办"），本文其余部分偏技术背景。

| 文档 | 内容 |
|---|---|
| **[docs/03-beginner-handbook.md](docs/03-beginner-handbook.md)** | **小白操作手册** ⭐：三条时间线、准备清单（含成本）、分工表、P0–P6 分阶段操作、45 个文件清单、Info.plist/权限、命令行编译、**20 条报错速查表**、验收测试清单、术语表、缺口补齐清单 |
| [docs/04-conversation-log.md](docs/04-conversation-log.md) | **对话与决策记录**：四轮问答的完整记录、实测数据、八条 ADR 决策、待办 |
| [docs/00-protocol-spec.md](docs/00-protocol-spec.md) | **协议实测规格**：包结构、启动契约、`/msg` 桥、路由表、配置契约、缓存与完整性、参考实现索引、多源家族对比 |
| [docs/01-dev-plan.md](docs/01-dev-plan.md) | **开发大纲与步骤计划**：目标/非目标、架构、技术选型、里程碑 M0–M8、**最快路径日级排期**、风险表、自签方案、CI 出包 |
| [docs/02-ui-spec.md](docs/02-ui-spec.md) | **UI 规格（两部分）**。结构：设计 token、信息架构、8 屏版面规格、组件库、**界面↔协议字段对照表**、五态矩阵、SwiftUI 要点、构建顺序。**细节**：动效 token、字体与 SF Symbols 图标表、手势交互矩阵、**浅色模式**、**弹幕渲染规格**、弹窗/Toast/空态错误**文案表**、数据格式规范、**设置项全表**、冷启动与降级规则 |
| [docs/07-冲刺计划.md](docs/07-冲刺计划.md) | ⏱ **7 天冲刺计划（最快路径）**：逐日清单 D0–D7、关键路径图、会吃掉时间的 4 件事、加速规则。**想最快做出来就先看这份** |
| [docs/08-P2操作卡.md](docs/08-P2操作卡.md) | 🔧 **P2/P3 逐步操作卡（有 Mac 时走这条）**：NodeMobile 下载、文件放哪、Build Settings 抄哪些值、真机验收逐条对照、P2/P3 专用报错表 |
| [docs/09-没有Mac也能装到手机.md](docs/09-没有Mac也能装到手机.md) | ☁️ **零 Mac 通路** ⭐（当前主路径）：GitHub 免费 macOS 机器编译出未签名 ipa → Windows 上用 Sideloadly 签名安装 → 7 天续签 |
| [docs/06-本会话完整记录.md](docs/06-本会话完整记录.md) | **本项目的完整对话记录**（自动导出、已脱敏）：每一轮你的提问 + 我的回答 + 工具调用（可折叠展开）。随时可用 `tools/export-session.mjs` 重新导出 |
| [docs/05-data-model.md](docs/05-data-model.md) | **数据 · 状态 · 错误 · 日志 · 设置键**：Swift 数据模型定义、SQLite schema、**多源状态机**、错误码表、日志规范（含脱敏要求）、**设置持久化键表**、版本与备份、非目标清单 |
| `docs/contract-notes.md` | （待产出）真跑实抓的 endpoint 与字段清单 |

## 设计稿

| 文件 | 内容 |
|---|---|
| [design/ui-mockup.png](design/ui-mockup.png) | ①首页 ②分类 ③详情 ④播放 ⑤设置 |
| [design/ui-mockup-2.png](design/ui-mockup-2.png) | ⑥搜索 ⑦片库 ⑧首次导入源 |
| `design/ui-mockup.html` / `ui-mockup-2.html` | 可编辑源码（改 CSS 变量换配色；用 Chrome 无头截图即可重新出稿） |

```bash
# 重新出稿（本机 Chrome/Edge 均可）
chrome --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1.6 \
       --window-size=2120,960 --screenshot=design/ui-mockup.png \
       "file:///<绝对路径>/design/ui-mockup.html"
```

## 工具（第 0 步，Windows 上就能跑）

| 工具 | 作用 | 安全 |
|---|---|---|
| `tools/probe/config-probe.mjs` | 体检订阅包：下载、MD5 校验、跳转链、MIME 伪装、**静态**提取配置与站点目录、提供者注册表、凭据字段长度 | ✅ 不执行任何下载到的 JS |
| `tools/host/node-host.mjs` | 桌面**参考宿主**：等价 FongMi 的 `NodeBundle` + `NodeService` + `NodeConfigMapper` + `NodeRoute` | ⚠️ 加 `--run` 才会执行第三方代码，**默认干跑** |
| `tools/host/bootstrap.js` | **启动契约**实现（`catServerFactory` / `catDartServerPort` / `/msg` 桥 / `runtime.start(config)`）—— 已逐字节同步到 `ios/Resources/bootstrap.js` | 同上 |
| `tools/host/p2-selftest.mjs` | **P2 链路桌面预演**：用 iOS 那份 `bootstrap.js` + 打桩 bundle，把 `serverStarted → /config → 站点映射` 全跑一遍。**不下载、不执行第三方代码** | ✅ 只跑自带文件 |
| `tools/check-swift-heuristics.mjs` | **Swift 粗略自查**（Windows 无编译器时的兜底）：括号平衡、中文引号、冲突标记、TODO、CRLF、文件行数总览 | ✅ 只读 |
| `tools/make-ios-package.mjs` | **一键重打包**给 Mac 的交付包 → `dist/Caty-P2P3-代码包.zip`（打前先跑自查 + P2 预演，任一失败不出包） | ✅ 只读源码 |

```bash
# 1) 安全体检（不执行代码）
node tools/probe/config-probe.mjs 'http://user:pass@host/index.js.md5' --out fixtures/mysrc

# 2) 干跑（只下载/校验/准备，不执行）
node tools/host/node-host.mjs 'http://user:pass@host/index.js.md5'

# 3) 真正启动 + 探测 endpoint（会执行第三方 Node 程序，请只用信任的源）
node tools/host/node-host.mjs 'http://user:pass@host/index.js.md5' --run --probe-routes
```

---

## 第一步 / 第二步（速览）

**第一步 —— M0：协议与运行时验证（2~4 天，不需要 Mac）**
用上面三个工具在桌面把源真正跑通，抓出 `/config`、`/config/sites/list`、`/spider/<key>/3?...` 的真实响应，
全部存成 `fixtures/`，写一份 `docs/contract-notes.md`。
验收：桌面能走完「导入源 → 分类 → 列表 → 搜索 → 详情 → 播放地址」，并有性能基线数字。

**第二步 —— M1：iOS 最小运行时 "Hello Node"（3~7 天，需要 Mac）**
建 SwiftUI 工程 → 集成 `NodeMobile.xcframework` → 后台线程 `node_start(…)` 跑 `bootstrap.js` →
Swift 侧实现 `/msg` 桥收 `serverStarted` → GET `/config` 打印站点列表。
验收：真机跑通 + 首屏耗时/内存/CPU 数字；**这一步是闸门** —— 若 iOS 无 JIT 下不可用，
立刻转 TrollStore+JIT 或"远程后端模式"，而不是继续做 UI。

---

## 安全与合规

- **只做容器**：本 App 不内置、不打包、不分发任何内容源，不含影视内容，不提供 VIP 解析或 DRM 绕过。
- **源是第三方可执行代码**：它在你 App 里拥有完整文件与网络权限，并且它的管理面板本身就在保管你的网盘
  cookie/token。→ 只用你信任的源；不要用主力网盘账号；`host-data/` 与运行期数据目录**绝不外发、绝不提交**。
- **只自签自用**：请勿公开分发、请勿上架、请勿收费。这类源聚合的多为第三方影视资源，存在版权风险，
  这是"自用工具"与"侵权工具"的分界线。
- **许可证**：参考实现（OKVideoMac）为 GPL-3.0，libmpv 亦涉 GPL。自签自用无实际约束，
  **但一旦分发就必须开源你的代码**；若想闭源分发，播放器改用 MobileVLCKit（LGPL）并避免照抄 GPL 代码。

## 工期与硬约束

三条可选时间线（只做 iPhone 也不能再省多少 —— 瓶颈不是设备类型）：

| 目标 | 工期 | 内容 |
|---|---|---|
| **A 能播** | **5–8 个工作日** | 导入源 → 文字列表 → 能播出画面（丑但能用） |
| **B 日常可用**（推荐） | **约 3 周** | A + 完整 8 屏界面 + 搜索/收藏/历史 + 源管理 |
| **C 全功能** | **6–8 周** | B + libmpv 硬解/字幕/弹幕渲染 + 直播 EPG + WebDAV + iPad |

**硬约束（都不是时间问题，是能不能做的问题）：**

- 当前开发机是 **Windows**；**M1 起必须有 Mac**（或 Actions 出未签名 ipa，但真机调试极痛苦）。
- 你的设备是 **iOS 27.0.1 → 用不了 TrollStore**（它只覆盖 14.0–16.6.1 / 17.0 部分），
  所以**"无 JIT"是既定前提**。对策：`module.enableCompileCache()`（已写进 `bootstrap.js`）+ 启动预热 + 首屏用缓存渲染。
  如果实测仍慢到不可用，退路是"远程后端模式"（把同一个 bundle 部署到 VPS，App 只做客户端）。
- 签名：免费 Apple ID（7 天续签、同时约 3 个 App）或付费账号（$99/年，省心）。

---

## 开新会话时怎么说（直接复制给 AI）

新会话会**自动读取 `AGENTS.md`**（里面写了全部技术事实、踩过的坑、出包流程），所以你只要说**要做什么**：

| 你的情况 | 直接复制这一句 |
|---|---|
| **报问题**（最常用） | `读 AGENTS.md。我用 Caty 遇到问题：<现象>。日志：<粘贴「复制日志」的内容>` |
| **继续做功能** | `读 AGENTS.md，然后做 P6：<例如 后台音频 + 播放手势>，做完出包给我装` |
| **小改动** | `读 AGENTS.md。把 <某处> 改成 <某样>` |
| **只要个包** | `读 AGENTS.md，重新出个包（dist/Caty-unsigned.ipa）` |

> **关键**：每次报问题都带上「设置 → 诊断与日志 → **复制日志**」的内容（已自动脱敏，
> 可以放心贴）。有日志 AI 能直接定位；只描述现象会多耗好几轮。

---

## 当前状态

**✅ A 方案（能播）已完成 —— 2026-10-09 真机实测通过**

用户没有 Mac，全程靠「GitHub 云端编译 + Windows 端 Sideloadly 签名」把 App 装进 iPhone（iOS 27.0.1）。
实测链路全通：

| 环节 | 实测数据 |
|---|---|
| 运行时 | Node **v24.20.0** arm64；`WebAssembly=object`、`fetch=function`（无 JIT 下可用） |
| 打桩源自检 | 启动 **0.08s** |
| 真源（6.5 MB bundle） | 启动 **0.78–0.82s**；`GET /config` → **94 个站点** |
| 源缓存 | 二次启动 **缓存命中，不重新下载**（P3 验收 ✓） |
| 浏览 | 站点 → 分类 → 列表（含封面图）→ 详情（含播放串）全通 |
| 播放 | **画面出来了**：直链站（柿子\|秒播）与网盘站（花卷\|4K / 夸克）都能播 |
| 网盘登录 | 内置配置中心（WKWebView）打开并成功登录夸克 → 播放拿到直链 ✓ |
| 源消息 | `toast` 提示能显示、`openInternalWebview` 能打开面板 ✓ |

**已知问题（按优先级）**
- [ ] **夸克空间不足或接口限额（code 32003）**：源"转存后播放"会失败，源自己会回退到 social 下载通道
      （有时成功）。属**账号侧**问题：清理夸克空间或换空间充足的账号即可，不是 App 缺陷。
- [ ] **文件夹条目**：像「【国剧】兰香如故.全集」这类目录项点进去显示"源没有返回这个条目的详情"
      —— 源用 `vod_tag=folder` + `action`/`style` 表示目录，App 还没实现"进入目录"，P5 补。
- [x] ~~个别站点自身报错（`虎斑|4K` 等）~~ → **2026-10-10 查明并修好**：真源为每个站点单独注册了
      `POST /spider/<key>/3/init`，站点靠它解析自己的上游域名；App 没调就是一直用源码里**写死的旧域名**
      → 界面只显示"请求失败"。现在每个站点在使用前先调一次 init，实测 `虎斑|4K` 从 15 秒超时变成 **90 ms 返回内容**，
      同类站点（多多 / 玩偶 / 木偶 / 花卷 / 观影 …）一并恢复。排错过程见 [docs/contract-notes.md §8](docs/contract-notes.md)。

**2026-10-10 第二轮已交付（用户 5 个诉求）**
- ✅ **换源不用关 App**：一个 Node 进程同时跑所有已启用的源（自研 bootstrap 多源模式 + 控制口 `/ctl/*`），
  设置页开关即时生效，首页左上角按源分组随时切换。
  桌面实测：两个真源同进程（42 + 94 站点）互不干扰；运行期追加源 **366 ms** 起来。
- ✅ 首页左上角源名**加粗 + 加大一号**；导航栏中间重复的源名**去掉**。
- ✅ 详情页「收藏 / 继续观看」改成**单独一行**（以前挤在海报右边，字一长就折行、位置不对）。
- ✅ 设置页源的 401 红字改成"要商家给的账号 / 不用就左滑删"这种能照做的文案。
- ✅ 播放失败**说清楚原因**（AVPlayer 的 item.error + errorLog + 后缀提示，mkv 会直接提示需要 mpv 内核）。

**下一步（P6）——播放内核（用户问"有些视频播不了、MPV 什么时候做"）**
1. **结论**：播不了多半是**内核**的事。现在用的系统 AVPlayer：MP4/HLS 没问题，**MKV 封装、
   部分 HEVC/AV1、软解字幕、2160p 高码率**它就不行。要解决就得加 **libmpv** 内核（自带 ffmpeg，
   一个内核覆盖上面全部）。"再加 2 个内核"没必要——libmpv 一个就够，AVPlayer 留着省电。
2. **落地步骤（已排期）**：(a) CI 里拿到 iOS 可用的 libmpv（优先用预编译 MPVKit，避免每次跑几十分钟）；
   (b) 播放页加"内核"选择（自动 / AVPlayer / mpv；默认自动：MP4 走 AVPlayer，MKV 或失败自动切 mpv）；
   (c) Metal 图层渲染 + 音画同步 + 字幕（内嵌/外挂）；(d) 真机逐项验收 2160p MKV / HEVC / 字幕。
   这一步要动 CI 和播放层，单独一轮做，做完才敢说"mkv 能播了"。

**已完成**
- [x] 协议逆向与实测（四件套 / 契约 B / 路由表 / 配置结构 / 三家族 24+32 提供者）
- [x] **UI 结构与版式规格 + 8 屏设计稿（PNG，可直接审阅）**
- [x] **小白操作手册 + 对话与决策记录 + 7 天冲刺计划**
- [x] `config-probe.mjs` —— 四源实测跑通（MD5 校验、302 跳转、MIME 伪装识别、契约判别、配置静态解析）
- [x] `node-host.mjs` —— 干跑验证（下载 / 校验 / 原子提交 / 缓存复用 / bridge 起停）
- [x] `bootstrap.js` —— 启动契约实现完成（含无 JIT 下的编译缓存优化 + iOS 的 portable 开关）
- [x] **运行时选型定案并实测核验**：`digidem/nodejs-mobile` **Node 24 `v24.20.0-0`（lite）**
      —— 官方 NodeMobile 只有 18.20.4，而 iOS 无 JIT 下 Node 18 没有 WebAssembly → `fetch` 是坏的，必须用 24 线。
      产物已下载核验：包内为 **Node v24.20.0**、含 **polywasm**、Mach-O arm64 **动态库**、最低 iOS 14.0，
      sha256 `991283d8579eee225142da2bf4a897dd7d831e8b5a496a1f247fca665bc1d705`
- [x] **P2 代码包**（`ios/`）：`NodeRuntime` / `BridgeServer`（NWListener /msg 桥）/ `BootstrapLoader`
      / `CatyLog`（环形缓冲+磁盘滚动+自动脱敏）/ 打桩 bundle / 自检屏 / 完整 `Info.plist` / 桥接头
- [x] **P3 代码包**：`SourceRecord`+`SourceStore`（JSON 清单）/ `BundleStore`（流式限量下载、拒绝 HTTPS→HTTP 降级、
      MD5 校验、staging 原子提交、缓存命中、镜像复用、契约判别）/ `RuntimeCoordinator` / `KeychainStore` / 源管理界面
- [x] **P4 代码包**（兼容层 + 播放器 + 四屏粗版）：
      `VodModels` / `NodeRoute` / `SiteMapper` / `PlayUrlParser` / `NodeClient` + `AVPlayerEngine`
      + 首页（站点）/ 分类列表（翻页）/ 详情（线路+选集）/ 播放（AVPlayer）→ **这一步就是"能播"**
- [x] **零 Mac 通路已搭好**：`ios/project.yml`（XcodeGen 生成工程）+ `.github/workflows/ios.yml`
      （借 GitHub 的 macOS 机器编译出**未签名 ipa**，自动下载 NodeMobile 并校验 sha256）
      + [docs/09-没有Mac也能装到手机.md](docs/09-没有Mac也能装到手机.md)（Windows 上用 Sideloadly 签名安装）
- [x] **零 Mac 通路已打通并跑出第一版 ipa** 🎉：仓库 → GitHub macOS runner 编译 → 未签名 ipa →
      Windows 上用 Sideloadly 装进 iPhone。**App 已在真机上跑起来**（三 tab 正常、bridge 监听、编译缓存路径正确）
- [x] **首次真机联调**：发现并修复 `/msg` 桥的连接生命周期 bug
      （`BridgeConnection` 临时对象被提前释放 → Node 的 `serverStarted` 汇报被静默丢弃 → 状态卡在「启动中」）；
      同时补了桥与 Node 线程的诊断日志
- [x] **桌面预演一次通过**：`node tools/host/p2-selftest.mjs` → `✓ P2 链路自检通过`
      （同一份 `bootstrap.js` + 打桩 bundle 跑通 `serverStarted → /config → 站点映射 → 列表/详情/取播放地址`）

**下一步（P5 已完成，以下是剩余打磨项）**

- [x] **P5 界面**：4 个 tab（首页 / 片库 / 搜索 / 设置）+ 源管理与诊断收进设置
- [x] **首页海报墙**（站点胶囊 / 分类胶囊 / 骨架屏 / 五态 / 翻页）
- [x] **分类浏览**：分类菜单 + **筛选项**（filters/extend）+ **目录条目**（`vod_tag=folder` 可递归进入）+ 翻页
- [x] **详情页**：海报头部 + 收藏 + 继续观看 + 线路切换 + 选集网格（标记在看的那集）+ 目录入口
- [x] **播放器**：进度条 + **断点续播**（记忆进度）+ 倍速菜单 + 上下集 + 播完自动下一集 + 15 秒进退
- [x] **片库**：收藏网格 + 历史列表（进度、相对时间、续播）
- [x] **设置**：播放 / 界面 / 源（配置中心、诊断入口）/ 存储（清缓存）/ 关于
- [x] **本地库**：收藏 / 历史 / 设置落盘（JSON，见 docs/04 ADR 10）；图片缓存 500 MB 磁盘 / 50 MB 内存
- [ ] 剩余打磨（P6 方向）：动效与手势、浅色模式、后台音频、libmpv（mkv/字幕/软解）、直播 EPG、弹幕渲染
