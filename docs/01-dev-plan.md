# iPhone 自签"通用源"播放器 —— 开发大纲与步骤计划

> 配套阅读：[00-protocol-spec.md](00-protocol-spec.md)（协议实测规格）。本文给"做什么、按什么顺序做、每步怎么验收"。

---

## 1. 目标与非目标

### 目标（v1 可交付）
1. iPhone 上自签安装、自己用的影视客户端。
2. **核心能力**：导入"通用接口"订阅（`http(s)://user:pass@host/index.js.md5`），
   与 MiraPlay / UZN / 羊壳 / 猫影视 / 猫爪 使用同一套源。
3. 完整闭环：导入源 → 首页/分类 → 详情 → 搜索 → 播放（含网盘源）→ 收藏/历史。
4. 源管理：多源共存、切换、更新检测、失败可回滚。

### 非目标（明确不做，避免项目失控）
- ❌ 不内置、不打包、不分发任何内容源（App 只是容器）。
- ❌ 不实现 VIP 视频解析、不绕过 DRM、不做"解析接口"。
- ❌ 不自研网盘协议（夸克/UC/天翼/139/迅雷）——**源自己已经实现了**，直接复用。
- ❌ 不上架 App Store（自签自用）。因此可以放开 ATS 等限制。
- ❌ v1 不做 Android / 不做多人/多账号。

### 用一句话定义 v1 的成功标准

> 在一台自签的 iPhone 上，粘贴一个 `index.js.md5` 订阅地址，30 秒内看到分类目录，点进去能播第一集。

---

## 2. 先看清三个现实约束

### 2.1 你现在的机器是 Windows，做不了 iOS 构建

`xcodebuild` / Swift 工具链只在 macOS 上。三条路：

| 路线 | 适用 | 说明 |
|---|---|---|
| **借/租 Mac**（推荐） | 真机调试、日常开发 | 任意一台 macOS + Xcode 16 即可；云 Mac（MacinCloud / MacStadium）也能开发但不能连你的 iPhone 调试 |
| **GitHub Actions 出包** | 无 Mac 时"能装到手机上" | `macos-14`/`macos-15` runner 上 `xcodebuild` + `CODE_SIGNING_ALLOWED=NO` 产出未签名 `.ipa`，再用 AltStore/Sideloadly 在本地自签安装。**你的 `gh` 已登录，这条路今天就能走通** |
| **只做协议与运行时验证** | 第一阶段 | 用桌面 Node 跑通全部协议（就是下面的 M0），**完全不需要 Mac** |

**结论**：M0 在 Windows 上就能做（本仓库 `tools/` 已备好）；M1 起需要 Mac 或 Actions。

### 2.2 iOS 上跑 Node：没有 JIT

- iOS 默认禁止 JIT（无法分配可执行内存），Node 的 V8 只能以无 JIT 模式运行，**性能明显低于桌面**。
- 对这个 6.4 MB 的 bundle（含 fastify + protobuf + 网盘解析）意味着：**首屏可能从 1 秒变成 5–15 秒**。
- 缓解手段（M1 就要试，不能等到最后）：
  1. **TrollStore**（iOS 14.0–16.6.1 / 17.0 部分版本）：可加 JIT 相关 entitlement，性能接近桌面 —— 如果能用，这是最优解；
  2. 常驻：App 启动即预热 Node，不要等用户点播才启动；
  3. 缓存：站点目录、搜索历史持久化，避免冷启动阻塞 UI；
  4. 兜底：若真源在无 JIT 下不可用，退化为"**远程后端模式**"——把同一个 bundle 部署在 VPS 上跑，
     App 只做 HTTP 客户端 + 播放器（协议完全一致，工作量反而更小，但需要你有台服务器）。

### 2.3 这类源是**第三方可执行代码**

它在你的 App 里拥有完整的 Node 能力（读写文件、发任意网络请求、加解密），并且它的管理面板本身就在保管你的网盘 cookie/token。
所以：只用你信任的源；不用主力网盘账号；data 目录不要外发。这不是可选项，是架构里要落地的隔离设计（见第 10 节）。

---

## 3. 架构总览

```
┌─────────────────────────────────────────────────────────────┐
│  SwiftUI 界面层                                              │
│  首页 / 分类 / 筛选 / 搜索 / 详情 / 播放 / 收藏历史 / 设置 / 源管理 │
├─────────────────────────────────────────────────────────────┤
│  站点聚合层（SiteAggregator）                                 │
│  · TVBox 兼容层：homeContent/categoryContent/detailContent/   │
│    searchContent/playerContent 语义                          │
│  · node:/spider/<key>/<type> 路由翻译（等价 NodeRoute）        │
│  · 播放串解析：vod_play_from/vod_play_url 的 $$$ / # / $       │
│  · 多源并发搜索 + 去重                                        │
├──────────────────────────┬──────────────────────────────────┤
│  源宿主层（SourceHost）   │  其他源类型适配器                  │
│  · NodeBundle 下载/MD5/  │  · TVBox 单仓/多仓 JSON           │
│    缓存/原子提交          │  · 苹果CMS (JSON/XML)            │
│  · 契约判别 (A/B)         │  · QuickJS 远程 JS 源（drpy 语法） │
│  · bootstrap + /msg 桥    │  · 直播 M3U/TXT + XMLTV          │
│  · 进程/实例生命周期、重启 │                                  │
├──────────────────────────┴──────────────────────────────────┤
│  Node 运行时（NodeMobile.xcframework，node_start）             │
│  宿主侧 HTTP 服务（本地回环 + 端口发现 + token 鉴权）             │
├─────────────────────────────────────────────────────────────┤
│  播放器：起步 AVPlayer(HLS/MP4) → 目标 libmpv(或 MobileVLCKit)  │
├─────────────────────────────────────────────────────────────┤
│  存储：SQLite/GRDB（收藏、历史、源配置、fixture）· Keychain（凭据）│
└─────────────────────────────────────────────────────────────┘
```

**数据流（一次播放）**：
```
用户点"播放"
 → 站点聚合层把请求翻译成 node:/spider/<key>/3?ac=play&... 
 → SourceHost 转发到 http://127.0.0.1:<port>/spider/<key>/3?...
 → bundle 内部：网盘解析/站点抓取 → 直链 + 必要的 header
 → 返回 vod_play_url（可能还要过 bundle 的 /proxy 才能防盗链）
 → 播放器交给 libmpv/AVPlayer 播放
```

---

## 4. 技术选型（含取舍理由）

| 组件 | 选择 | 理由 / 备选 |
|---|---|---|
| 语言/UI | **Swift 6 + SwiftUI**，iOS 16+ | 自签不需要兼容老系统；SwiftUI 出活快。复杂列表页必要时嵌 UIKit |
| Node 运行时 | **NodeMobile.xcframework**（社区 fork：`nodejs-mobile/nodejs-mobile`、`1Conan/nodejs-mobile`） | 唯一成熟路线。备选：自己编 libnode（工作量大 2–3 周，只在 NodeMobile 不可用时才走） |
| 宿主 HTTP 服务 | **NWListener**（原生）或 **GCDWebServer** | NodeMobile 参考实现用 GCDWebServer；NWListener 更现代但需要自己写路由。Bridge 只需 1 个 POST 路由，建议 NWListener |
| 播放器 | 起步 **AVPlayer**，目标 **libmpv**（render API + Metal/OpenGL） | AVPlayer 零成本覆盖 HLS/MP4（多数源）；网盘 mkv/H265/字幕/软解必须 libmpv。备选 MobileVLCKit（LGPL、体积大） |
| 网络 | URLSession（可配 delegate 做流式限量下载）；bundle 侧网络由 Node 自己发 | 不要用 Alamofire 之类，没收益 |
| 存储 | **GRDB**（SQLite） | 收藏/历史/缓存/源配置；性能与可控性优于 SwiftData |
| 密码/凭据 | **Keychain** | 源配置里的 cookie/token 不要明文放文件 |
| 依赖管理 | SPM（NodeMobile 用 xcframework 二进制目标） | 不要混 CocoaPods，除非用 VLCKit |
| 日志 | `os.Logger` + 自建 ring buffer + 导出 | 这类项目调试量极大，日志体系要早做 |

**许可证提醒**：OKVideoMac 是 **GPL-3.0**，libmpv 也是 **GPL/LGPL 双许可（GPL 部分）**。
自签自用无实际约束；**但只要你把 App 分发给别人，就必须遵守 GPL（开源你的代码）**。
如果未来想闭源分发：播放器改用 **MobileVLCKit（LGPL，动态链接可满足）**，并避免照抄 GPL 代码。

---

## 5. 里程碑总览

| 里程碑 | 内容 | 工期（单人） | 验收标准（可测） |
|---|---|---|---|
| **M0** | **协议与运行时验证（桌面）** | 2–4 天 | 桌面完整走通"导入源→分类→列表→搜索→详情→播放地址"，全部响应存档为 fixture |
| **M1** | **iOS 最小运行时 "Hello Node"** | 3–7 天 | App 内跑起真源，收到 `serverStarted`，Swift 侧 GET `/config` 打印出站点列表 |
| M2 | 源管理与缓存（下载/MD5/原子提交/多源/更新/重启） | 4–6 天 | 冷启动不重下；源更新自动生效；杀掉 Node 能自愈；多源互不干扰 |
| M3 | TVBox 兼容层 + 站点目录闭环 | 5–8 天 | 首页出现分类、分类出列表、详情出播放源、搜索出结果（UI 可先用最简 List） |
| M4 | 播放器 MVP + 播放闭环 | 5–7 天 | 能播放 m3u8 与至少一个网盘源；倍速/选源/选集/断点续播 |
| M5 | UI 成型 | 10–15 天 | 首页/分类/筛选/搜索/详情/播放/收藏/历史/设置/源管理 全部可用 |
| M6 | 多引擎扩展 | 10–15 天 | 同时支持 TVBox JSON 单仓多仓、苹果CMS、QuickJS JS 源、直播 M3U+EPG |
| M7 | 凭据与网盘登录 | 3–5 天 | 用 WebView 打开 bundle 的 `/website` 面板完成网盘登录并回写凭据 |
| M8 | 自签、CI、稳定性（持续） | 持续 | 一键出包 + 续签流程稳定 + 崩溃率可观测 |

**基准估算：单人全职约 8–12 周到"日常可用"**（不含 M6/M7 约 6–8 周）。
其中 **M0 与 M1 决定整个项目成败**，不要跳过、不要并行。

### 5.1 最快路径（"越快越好"时按这个压缩）

压缩靠四件事，按收益排序：

1. **借源的能力，不自己造**：用 B 类全功能源（9.2 MB 那个），它自带 `live`/`cms`/`t4`/`emby`/`pansou`/`webdav`/`danmu`
   → **M6 的绝大部分直接消失**；网盘登录用 WebView 打开源自带的 `/website` → **M7 从 3–5 天压到 0.5 天**。
2. **UI 与协议并行推进**：协议（M0/M1）在 Mac 上验证的同时，UI 骨架可以在拿到 fixture 后先搭（详见 [02-ui-spec.md](02-ui-spec.md) §10）。
3. **砍范围**：v1 不碰 libmpv 硬解/字幕渲染（先用 AVPlayer 跑通 HLS/MP4）、不做 iPad、不做下载、不做多用户。
4. **用 AI 辅助按天产出代码**：每个里程碑我直接给可编译的 Swift 文件，你只负责在 Mac 上编译、真机验证、报错回传。

**最快排期（工作日，单人 + AI 协助，前提是有 Mac、源稳定）：**

| 天 | 里程碑 | 产出 |
|---|---|---|
| D1–D2 | M0 | 真跑源 + 抓 fixture + `contract-notes.md` |
| D3–D6 | M1 | Xcode 工程 + NodeMobile + bootstrap + `/msg` 桥 + `/config` → **性能闸门** |
| D7–D9 | M2 + U1/U2 | 缓存/镜像/源管理 + 运行时状态页 + 首次导入引导 |
| D10–D12 | M3 + U3 | TVBox 兼容层 + 首页/分类/详情（粗版全链路打通） |
| D13–D15 | M4 + U4 | 播放器 + 线路/选集 → **第一个完整闭环** |
| D16–D21 | M5 + U5/U6 | 海报网格、沉浸详情、zoom 转场、骨架五态、搜索聚合、片库、主题色 |
| D22–D24 | M8 | 真机打磨、自签流程、日志导出 |

→ **约 22–24 个工作日 ≈ 4.5–5 周**，得到"界面完整、日常可用"的 v1。
一切顺利（M1 一次通过、源不改协议、每天 6–8 小时）：**最快 3 周**。

要"全功能"（libmpv 硬解/字幕/弹幕渲染、直播 EPG、WebDAV、多源去重调优、iPad、完整设置）：
**再 +2–3 周 → 合计 6–8 周**。

### 5.2 真正的瓶颈不是写代码

按"会不会卡住项目"排序：

1. **没有 Mac** → M1 根本开不了工。可以走 GitHub Actions 出未签名 ipa，但真机调试极痛苦。
   **如果你现在没有 Mac，最快路径不是写代码，而是先解决 Mac。**
2. **iOS 无 JIT**（你的 iOS 27 拿不到 TrollStore，下面 §11 说明）→ 9.2 MB bundle 的**解析**开销是主要成本。
   第一优先优化：若运行时里的 Node ≥ 22，打开 `module.enableCompileCache()` —— 把"每次启动都解析 9 MB JS"
   变成"只有第一次解析"，这是这条路上最大的一笔性能账。
3. **源站改协议**：四个源实测契约一致，短期风险低；一旦加签名清单，M8 的 manifest 校验要提前做。
4. **真机适配**：网盘播放直链的 header/防盗链问题通常花掉 2–3 天，预留。

---

## 6. 第一步（M0）：协议与运行时验证 —— 2~4 天，不需要 Mac

> **为什么第一步是这个**：整个 App 的价值 = 正确复刻宿主的启动/桥接协议。
> 协议理解错，后面 8 周全部白做。而这一步在 Windows 上就能完成，且产出的 fixture 会成为
> iOS 侧的"验收数据集"。

### 6.1 具体动作

**① 静态体检（安全，不执行任何下载到的 JS）**

```bash
cd /d/Zcode/Catys
node tools/probe/config-probe.mjs 'http://<user>:<pass>@<host>/index.js.md5' --out fixtures/mysrc
# 想看配置内部任意子树（自动脱敏）：
node tools/probe/config-probe.mjs '<URL>' --out fixtures/mysrc --dump sites --dump alist --dump pans
```
产出：`fixtures/mysrc/report.json`（体检表 + 站点目录 + 提供者注册表 + 凭据字段清单）与原始文件。

**本次已跑通的结论**（见 [00 文档 §8、§9.1](00-protocol-spec.md)）：4 个订阅（3 个家族）**全部**为 contract-b；
MD5 全部校验通过；其中两个源是**同一 bundle 的逐字节镜像**；配置均可静态解析（24 与 32 提供者两档，
第三个只剩 `customSpiders`）；**`sites.list` 全部为空**（站点目录只能从运行时拿）。

**② 真跑起来（会执行第三方代码，请自行判断环境）**

```bash
# 默认就是干跑：只下载 + MD5 校验 + 缓存提交 + 起 bridge，不执行第三方代码
node tools/host/node-host.mjs 'http://<user>:<pass>@<host>/index.js.md5'

# 确认无误后真正启动，并做 endpoint 探测
node tools/host/node-host.mjs 'http://<user>:<pass>@<host>/index.js.md5' --run --probe-routes
```
它会打印：`serverStarted` 回报的本地地址 → `GET /config` 的站点目录 → 按 `NodeConfigMapper` 语义映射出的
`node:/spider/<key>/<type>` 站点清单 →（`--probe-routes` 时）逐个 endpoint 的状态码与响应片段。
跑完不退出，会打印本地地址，方便你继续用 curl 探索。

**③ 抓 fixture（本步最重要的产出）**

用 curl 手工打本地服务，把关键请求/响应存成 golden file：

```bash
BASE='http://127.0.0.1:<port>'
curl -s $BASE/config                       > fixtures/mysrc/res_config.json
curl -s -X POST $BASE/init -H 'content-type: application/json' -d '{}' > fixtures/mysrc/res_init.json
curl -s "$BASE/spider/<key>/3?ac=detail"   > fixtures/mysrc/res_detail.json
curl -s "$BASE/spider/<key>/3?ac=list"     > fixtures/mysrc/res_list.json
curl -s "$BASE/spider/<key>/3?ac=search&wd=测试" > fixtures/mysrc/res_search.json
```
（endpoint 命名以实抓为准 —— 这正是本步要"发现"的东西，见 00 文档 §9.2 待验证项。）

**④ 记录性能基线**：首屏耗时、常驻内存、空闲 CPU、bundle 启动日志。

**⑤ 写 `docs/contract-notes.md`**：把发现的 endpoint 命名、字段结构、`/proxy` 参数约定写下来。

### 6.2 验收标准

- [ ] `index.js` 的 MD5 与 `.md5` 文件完全一致，且能解释那条 302 + 伪装 JPEG 的链路
- [ ] 桌面宿主成功收到 `serverStarted`，拿到本地地址
- [ ] `GET /config` 能解析出站点目录（≥1 个站点，字段含 route）
- [ ] 至少 3 个 endpoint 的真实响应已存为 fixture
- [ ] 有性能基线数字（否则 M1 无从对比）
- [ ] 结论明确：**该源属于 contract-b（宿主集成型）**，需要完整 bootstrap 协议

### 6.3 本步常见坑

- Node 的 `fetch` **拒绝带凭据的 URL** → 必须手动拆 userinfo 转 `Authorization: Basic`
- `Content-Type` 是假的 → 一律当文本读
- MD5 要算**响应体字节的 MD5**（不是跟随跳转前的重定向页）
- bundle 需要 `process.chdir(dataRoot)` + `HOME=dataRoot`，否则它可能往当前目录写垃圾
- Windows 下路径要用绝对路径（bundle 内部有 `node:path` 与 `node:fs` 操作）

---

## 7. 第二步（M1）：iOS 最小运行时 "Hello Node" —— 3~7 天，需要 Mac

> **为什么第二步是这个**：先证明"**在 iPhone 上真的能跑起来 + 性能可接受**"，再投入 UI。
> 如果这一步不通过，架构要立刻改（转 TrollStore+JIT，或转远程后端模式）——早发现比晚发现省一个月。

### 7.1 具体动作

**① 工程骨架**
```
Caty.xcodeproj            SwiftUI App，iOS 16+，Bundle ID: com.<you>.catnode
  Sources/App/               入口、路由、主题
  Sources/Runtime/           NodeRuntime.swift / BridgeServer.swift / NodeBundleStore.swift
  Sources/Compat/            TVBoxCompat/ NodeRoute.swift / VodParser.swift
  Sources/Player/            PlayerView.swift（先 AVPlayer）
  Sources/Store/             GRDB 模型
  Resources/bootstrap.js     ← 从 M0 的 tools/host/bootstrap.js 原样搬入
  Frameworks/NodeMobile.xcframework  ← SPM 二进制目标
```

**② 集成 NodeMobile**
- 从 `nodejs-mobile/nodejs-mobile`（社区活跃 fork）或 `1Conan/nodejs-mobile` 取 iOS xcframework；
- SPM 用 `.binaryTarget` 引入；或直接从成熟示例里提取 arm64 slice（`JackLeeo/tvbox_flutter` 的 `ios/Frameworks/NodeMobile.xcframework` 可直接参考其集成方式）；
- 验证：一个空白工程能成功链接并调用 `node_start`。

**③ `NodeRuntime.swift`（等价 FongMi `NodeService`）**
```swift
// 在专用后台线程执行（Node 会长期占用该线程）
let code = node_start(["node", bootstrapPath, indexPath, configPath, dataRoot,
                       String(bridgePort), token])
```
要点：Node 运行时**不是主线程**；退出即视为崩溃，需按退避重启；只允许 `<沙箱>/nodejs/` 下的路径（canonical 校验）。

**④ `BridgeServer.swift`（等价 `/msg` 桥）**
- `NWListener` 绑定 `127.0.0.1` + 随机端口（或固定端口再探测）；
- 唯一路由 `POST /msg`，校验 `X-CatVod-Token`；
- 解析 `{"action":"serverStarted","opt":{"address":...}}` → 保存为 `serviceBaseURL`；
- `nodeError` → 展示可读错误（"源脚本启动失败：<message>"）。

**⑤ `bootstrap.js`**：把 M0 验证过的版本搬进 App 资源（语义一字不改；它必须注入
`catServerFactory` / `catDartServerPort`、patch `http.request`、设置 `CATVOD_DISABLE_AUTOSTART` 等）。

**⑥ 先用打桩 bundle 自证链路**（20 行）：
```js
module.exports = { default: { async start(config) {
  const server = globalThis.catServerFactory((req,res)=>{ res.end(JSON.stringify({ok:req.url})) })
  server.listen()
}}}
```
跑通"start → listening → serverStarted → Swift 侧 GET" 后，再换真源。

**⑦ 换真源，测四件事**：首屏耗时 / 常驻内存 / 空闲 CPU / 是否崩溃。**这就是 M1 的闸门。**

**⑧ 工程配置**
- ATS：本地回环 + 任意 HTTP 源 → `NSAllowsArbitraryLoads` + `NSAllowsLocalNetworking`（自签无审核风险）
- 后台：`beginBackgroundTask` 保活，回前台探活重启；接受"后台被杀"这个现实，做好恢复逻辑
- 体积：NodeMobile 静态库 + 播放器会让 IPA 上到 100–200 MB，属正常

### 7.2 验收标准

- [ ] 真机（不是模拟器）上成功 `serverStarted`
- [ ] Swift 侧 GET `http://127.0.0.1:<port>/config` 拿到 JSON 并打印站点列表
- [ ] 打桩 bundle 与真源都能跑
- [ ] 有真机性能数字：首屏 ___ 秒，常驻 ___ MB，空闲 CPU ___%
- [ ] **闸门决策**：性能可接受 → 按原计划进 M2；不可接受 → 转 TrollStore+JIT 或远程后端模式

### 7.3 M1 三大技术风险（提前想好对策）

| 风险 | 现象 | 对策 |
|---|---|---|
| 无 JIT 太慢 | `/config` > 20s 或超时 | TrollStore 加 JIT entitlement；预热；缓存目录；远程后端模式 |
| 单进程只能一个 Node 实例 | 多源冲突/端口冲突 | 自研 bootstrap 支持单实例多 bundle（各自独立 data 目录 + bridge 端口）；否则"同时只激活一个源" |
| Node 崩溃拖死 App | 整个 App 退出 | Node 放独立线程 + 崩溃隔离 + 退避重启 + UI 降级（其他源类型仍可用） |

---

## 8. M2 ~ M8 要点（按顺序做，每步都可独立验收）

- **M2 源管理与缓存**：实现 00 文档第 5 节全部内容。**关键调整：缓存按 bundle MD5 建条目**，
  订阅 URL 只作为"源记录"并维护**镜像列表**（同一 MD5 可挂多个 URL，换镜像不重下 6–9 MB，
  顺带获得镜像故障自动切换）。其余同前：MD5 校验、staging + 原子提交、`.pending` 崩溃恢复、
  大小上限流式限量、超时策略、签名钉扎留接口。
  验收：冷启动 0 下载；**换镜像不重下**；源更新自动拉取；手动清缓存可恢复。
- **M3 TVBox 兼容层**：站点目录映射（`/config` → `video.sites[]` → `node:/spider/<key>/<type>`）、
  路由拼接（等价 `NodeRoute`）、`vod_play_from/vod_play_url` 解析器（`$$$`/`#`/`$` + 全角反向兼容）、
  多源并发搜索去重。验收：最小 UI 下能走完"分类→列表→详情→取到播放地址"。
- **M4 播放器 MVP**：AVPlayer 起（HLS/MP4）→ 选源/选集/倍速/AirPlay/画中画/断点续播；
  再上 libmpv 补 mkv/H265/字幕/软解；`/proxy` 中转的 header 处理（Referer/UA 注入）。
  验收：至少 1 个网盘源 + 1 个普通源可播放。
- **M5 UI 成型**：首页（多源聚合）/分类/筛选器/搜索（含聚合搜索）/详情/播放页/收藏/历史/设置/
  源管理/日志导出。用配置里的 `color` 主题色板驱动皮肤（源自带配色，能显著提升观感）。
- **M6 多引擎扩展**（按需）：QuickJS（JS 源 `homeContent` 等 drpy 语法）、TVBox 单仓/多仓 JSON、
  苹果CMS JSON/XML、直播 M3U/TXT + XMLTV EPG。
  ⚠️ **先别急着自己写**：实测 B 类 bundle（9.2 MB 那个）配置里已经带了
  `live` / `cms` / `t4` / `emby` / `pansou` / `webdav` / `danmu` 模块 —— **导入一个源就可能直接覆盖这里的大半能力**。
  所以 M6 应排在 M5 之后，并且先实测 B 类源已经覆盖到什么程度，避免重复造轮子。
- **M7 凭据/网盘登录**：WebView 打开 bundle 的 `/website`（内含 quark/pan189/pan115/pan123/139/thunder/bili
  登录与 WebDAV 备份），或原生实现登录并写回 bundle 配置。
- **M8 自签与 CI**：见第 11 节。

---

## 9. 风险清单（按杀伤力排序）

| # | 风险 | 影响 | 对策 |
|---|---|---|---|
| 1 | iOS 无 JIT 导致真源不可用 | 致命 | M1 就做闸门验证；TrollStore+JIT；远程后端兜底 |
| 2 | 源站改协议/加签名清单 | 高 | 契约判别 + 明确报错；实现 manifest 校验；保留"旧版可用"回滚 |
| 3 | 多源并发与单 Node 实例冲突 | 高 | 单实例多 bundle bootstrap（独立端口/数据目录）；M3 前定案 |
| 4 | 凭据落盘泄露（网盘 cookie/token） | 高 | 沙箱隔离 + Keychain + 不外发 + 不提交仓库；UI 明示风险 |
| 5 | 版权合规 | 高 | 仅自签自用；不内置/不分发/不售卖；App 不含任何内容 |
| 6 | bundle 内存增长（fastify+protobuf+网盘缓存） | 中 | 内存监控阈值 + 自动重启 + 限制并发 |
| 7 | 后台挂起导致服务不可用 | 中 | `beginBackgroundTask` + 回前台探活重启 |
| 8 | 源站域名/跳转/伪装 MIME 变化 | 低 | 不信任 Content-Type；手动跳转；UA/Referer 可配；超时可控 |
| 9 | 代码许可证（GPL-3.0 传染） | 低（自用）/高（分发） | 只在参考层面学习；分发前替换视频/播放器依赖并开源 |
| 10 | 免费证书 7 天过期 | 低 | SideStore/TrollStore/付费证书（见第 11 节） |
| 11 | bundle 会**再起本地服务 / 拉取并执行二级 JS** | 中 | `danmuBuiltin{host,port,token,autoStart}` 会另开端口，`customSpiders{dir,urls}` 会远程拉 JS 执行 → 宿主不能假设"只有 `serverStarted` 一个端口"；首次导入的信任提示与数据一键清空是必需功能 |

---

## 10. 合规与安全（写进代码里的三条）

1. **容器原则**：App 不内置任何内容源，不含任何影视内容，不提供解析能力；用户自行导入订阅。
2. **第三方代码提示**：首次导入源时明确告知"该源是第三方程序，将在本机运行并可访问网络与本地存储"，
   并提供"暂停/删除源 + 清空数据"入口。
3. **凭据最小化**：不引导用户使用主力账号；源产生的凭据只存沙箱与 Keychain；支持一键清空。

> 法律层面：这类源聚合的通常是第三方影视资源，可能涉及侵权。请保持"自签自用"边界，
> 不要公开分发、不要上架、不要收费。这一点不是形式主义 —— 它是"自用工具"与"侵权工具"的分界线。

---

## 11. 自签与部署方案

> **你的设备是 iOS 27.0.1，先把这一条定下来**：TrollStore 只覆盖 iOS 14.0–16.6.1 与 17.0 的部分版本，
> **iOS 27 用不了**。所以对你而言：
> - 拿不到 JIT 相关 entitlement → **"无 JIT"是既定前提，不是备选方案**，
>   `module.enableCompileCache()` 这类一次性编译缓存必须在 M1 就试；
> - 现实方案是 **SideStore**（7 天自动续签，需设备端配合）或 **付费开发者账号**（$99/年，省心）；
> - 具体签名工具对 iOS 27 的支持情况以你机器上实测为准 —— 我不臆测未经验证的版本策略。

| 方案 | 有效期 | 限制 | 适用 |
|---|---|---|---|
| **TrollStore** | 永久 | 仅 iOS 14.0–16.6.1 / 17.0 部分 | **你的 iOS 27 用不了**（若将来换设备/降级，这是最优解） |
| **SideStore** | 7 天自动续签 | 需设备端配合 VPN/StosVPN；免费 Apple ID | 无 Mac 时的长期方案 |
| **AltStore + AltServer** | 7 天 | 需电脑同网段定期续签；免费账号最多 3 个 App | 入门 |
| **Sideloadly / 轻松签 / 全能签** | 7 天或证书期 | 手动；企业证书有风险 | 临时安装/联调 |
| **付费开发者账号** | 1 年 | $99/年；仍无 JIT（除非 TrollStore） | 想少折腾续签 |
| **越狱** | 永久 | 取决于设备/版本 | 不推荐（维护成本） |

**CI 出包（无 Mac 时的关键路径）**：
```
GitHub Actions (macos-15 runner)
  → xcodebuild -scheme CatNode -configuration Release \
      -destination 'generic/platform=iOS' \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
  → 打包 Payload/ 为 unsigned .ipa
  → artifact 下载 → Sideloadly/AltStore 用你的 Apple ID 重签安装
```
注：NodeMobile 这类含静态库的工程在 CI 上只编 arm64 可显著缩短时间；`xcframework` 里的模拟器 slice 不必打包。

---

## 12. 建议的工程目录（同时是 M0 的当前状态）

```
Catys/
├── README.md
├── docs/
│   ├── 00-protocol-spec.md      ← 已写：实测协议规格
│   ├── 01-dev-plan.md          ← 本文
│   └── contract-notes.md        ← M0 产出：真实 endpoint/字段清单
├── fixtures/                    ← M0 产出：golden file（请求/响应存档）
├── tools/                       ← M0 用，Windows 可跑
│   ├── probe/config-probe.mjs   ← 安全静态体检（不执行 JS）
│   └── host/
│       ├── node-host.mjs        ← 桌面参考宿主（等价 NodeService+NodeConfigMapper+NodeRoute）
│       └── bootstrap.js         ← 启动契约实现，M1 直接搬进 iOS 工程
└── (M1 起) Caty.xcodeproj / Sources/ / Resources/ / Frameworks/
```

---

## 13. 调试技巧（省时间的）

1. **先把 Node 侧当黑盒**：M0 用 `curl` 打本地端口，比在 Swift 里断点快 10 倍。
2. **保留 bundle 的原始日志**：bundle 内部有 `[system] [server] ...` 之类的日志（实测存在），
   Node 的 stdout/stderr 一定要转发到宿主日志，否则排障是盲的。
3. **端口别写死**：`listen` 应绑定 `port:0` 再读回真实端口（引用实现就是强制这样做的），
   避免与其他 App 冲突。
4. **fixture 优先**：M3 写 TVBox 兼容层时用 fixture 做单测，不要每次都真跑 Node。
5. **契约判别要早**：加载前先做 `catServerFactory`/`catDartServerPort`/`DEV_HTTP_PORT` 静态扫描，
   不匹配就明确报"不支持的源契约" —— 这是最省心的失败方式。
6. **给源站留后门**：UA / Referer / 是否跟随跳转 / 超时 全部做成可配置项，
   源站一变你改配置而不是改代码。
