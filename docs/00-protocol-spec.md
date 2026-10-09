# 通用接口（Node 内置源）协议规格 —— 实测版

> 本文所有"实测"标注项均由本次对真实源 `http://<user>:<pass>@cat.xn--4kq62z5rby2qupq9ub.top/index.js.md5`
> 的抓取与对两套开源客户端的源码阅读得到；"引用实现"标注项来自公开仓库源码；"推断"标注项未直接验证。
> 文档中的订阅 URL 已抹除口令。

---

## 0. 一句话结论

**这类"源"不是一份规则配置，而是一整个 Node.js 服务端程序。**
客户端要做的是：**下载它 → 校验 MD5 → 用内置 Node 运行时把它跑起来 → 它会监听本地回环端口 → 客户端通过 HTTP 把它的接口翻译成站点目录，再交给播放器。**

所以目标 App 的本质是三个东西：

```
Node 运行时宿主（最核心）  +  TVBox 兼容层（协议翻译）  +  播放器/UI
```

不是"JS 规则解释器"，也不是"远程 JSON 配置解析器"。这是整个项目成败判断的第一前提。

---

## 1. 订阅包结构

一个"通用接口"订阅地址，指向一个**四件套 + 可选签名清单**：

| 文件 | 作用 | 上限（引用实现） |
|---|---|---|
| `<base>/index.js.md5` | 订阅标记 + `index.js` 的 MD5（32 位 hex） | 1 KB |
| `<base>/index.js` | **Node.js 程序**（esbuild 打包，导出 `start(config)`） | 32 MB |
| `<base>/index.config.js` | 默认配置（**是 JS 文件，但内容为静态对象字面量**） | 2 MB |
| `<base>/index.config.js.md5` | `index.config.js` 的 MD5 | 1 KB |
| `<base>/<manifest>` | 可选：sha256 签名清单（防降级/防篡改） | 32 KB |

### 实测数据（该源，2026-10-09）

```
index.js.md5           200  32 B       application/octet-stream
                       内容: e5b9b774af06f3014f4cf0087cdf07a9

index.js               302  → http://oss4liview.moji.com/thd_file/2026/10/05/603d3daf40129d308dece13f207094a0.jpg
                       200  6,486,569 B  Content-Type: image/jpeg   ← MIME 伪装，实际是 JS
                       ETag: "E5B9B774AF06F3014F4CF0087CDF07A9"   ← 与 index.js.md5 完全一致

index.config.js.md5    200  32 B       → 93f807174a2f253cdcf5ce9ee00f4c18
index.config.js        200  9,809 B    Content-Type: image/jpeg   ← 同样是伪装成 JPEG 的 JS
根路径 /               200  9 B         "你好！"
/config.json           404 (nginx)     ← 说明订阅站只是静态分发站，不是接口服务
```

**要点（务必在客户端实现里体现）：**

1. **不要信任 `Content-Type`**，一律按文本/JS 处理。
2. **必须手动跟随 302 跳转**，并且跳转目标可能是另一个域名（本例是 OSS）。
3. 源站把 JS 伪装成 `.jpg`，说明它刻意规避按扩展名做的内容过滤 —— 客户端只需容错，无需在意原因。
4. `.md5` 文件内容可能带空白/换行（引用实现的匹配正则是 `(?i)(?:^|\s)([a-f0-9]{32})(?:\s|$)`），解析时要 trim。
5. 该源 URL 带 Basic Auth（`user:pass@`），必须解析 userinfo → `Authorization: Basic ...`，并把 userinfo 从请求 URL 中剔除（现代 HTTP 客户端如 Node 的 fetch 会直接拒绝带凭据的 URL）。

---

## 2. 客户端启动契约（最关键的 80 行）

引用实现：FongMi（Android）`nodejs/src/main/assets/nodejs/bootstrap.js` + `NodeService.java`；
Apple 平台等价物：`OKVideoMac/.../NodeBundleRuntimeService.swift`；iOS 现成参考：`JackLeeo/tvbox_flutter` 的 `ios/Runner/NodeJSManager.m`（用 `NodeMobile.xcframework` + GCDWebServer）。

### 2.1 启动命令

宿主（App）用**内置的 Node 运行时**执行一个自带的 `bootstrap.js`，并把参数传进去：

```
node  <bootstrap.js>  <index.js 绝对路径>  <index.config.js 绝对路径>  <dataRoot 绝对路径>  <bridgePort>  <token>
       argv[0]  argv[1]        argv[2]              argv[3]                argv[4]        argv[5]     argv[6]
```

等价于 Android 侧的 `startNodeWithArguments({"node", bootstrap, index, config, data, bridgePort, token})`；
在 iOS 上就是 `node_start(argc, argv)`（NodeMobile.framework）。

### 2.2 bootstrap 必须做的六件事

1. **设置环境**（这是 bundle 内部约定的开关）：
   ```
   process.env.CATVOD_DISABLE_AUTOSTART = '1'   // 告诉 bundle：别自己 listen，等宿主给 factory
   process.env.HOST   = '127.0.0.1'
   process.env.PORT   = '0'                     // 随机端口
   process.env.HOME   = dataRoot
   process.chdir(dataRoot)
   ```
2. **注入两个全局函数**（bundle 靠它们与宿主协作）：
   - `globalThis.catServerFactory(handler)`：宿主提供的 HTTP 服务器工厂。bundle 调用它拿到一个 server 对象，
     并期望该对象的 `listen()` 被**强制绑定到 `{host:'127.0.0.1', port:0, exclusive:true}`**（只监听回环、随机端口）。
   - `globalThis.catDartServerPort()`：返回宿主的 bridge 端口。
3. **打补丁 `http.request`**：凡是 `POST http://127.0.0.1:<bridgePort>/msg` 的请求，自动加上
   `X-CatVod-Token: <token>` 头。这样 bundle 无需知道 token 也能安全回调宿主。
4. **端口回收**：监听 `server.once('listening')`，把真实地址通过桥上报（见 2.3）。
5. **加载并启动 bundle**：
   ```js
   const configModule = require(configPath)
   const indexModule  = require(indexPath)
   const config  = configModule.default || configModule
   const runtime = indexModule.default  || indexModule
   if (typeof runtime.start !== 'function') throw new Error('Node bundle does not export start()')
   await runtime.start(config)          // ← 唯一的入口契约
   ```
   即 **bundle 必须 `export default { async start(config) {...} }`**（实测该 bundle 中确实存在
   `class { constructor(t){this.server=t} async start(t){...} }` 形态）。
6. **错误上报**：`start()` 抛错时向 `/msg` 发 `{action:'nodeError', opt:{message}}`，短暂延时后 `process.exit(1)`。

### 2.3 运行时 → 宿主的回报消息

`POST http://127.0.0.1:<bridgePort>/msg`，`Content-Type: application/json`，头带 `X-CatVod-Token`：

```json
{ "action": "serverStarted",
  "opt": { "address": "http://127.0.0.1:54321", "token": "...", "pid": 1234,
           "version": "v22.x", "arch": "arm64" } }
```

`address` 就是**本地业务服务的根地址**，宿主要把它存下来，后续所有请求都打这个地址。
失败时为 `{"action":"nodeError","opt":{"message":"..."}}`。

### 2.4 两种运行契约（Apple 平台实现的静态判别法）

引用实现（OKVideoMac `NodeRuntimeContract.swift`）在**不执行代码**的前提下，扫描 `index.js` 源码里的三个标记：

| 标记组合 | 契约类型 | 宿主需要做什么 |
|---|---|---|
| `catServerFactory` + `catDartServerPort` + `DEV_HTTP_PORT` **全部出现** | `contract-b-host-integrated` | 必须按 2.1–2.3 完整实现 bootstrap 与桥 |
| 三个都不出现 | `contract-a-service` | 服务自监听，宿主靠约定端口/状态文件探测就绪 |
| 只出现其中一部分 | **拒绝加载**（不支持的契约） | 明确报错，不要猜 |

**实测你这套源：三个标记全部存在** → 属于 `contract-b-host-integrated`，即**必须**实现完整 bootstrap 协议。

> 实现建议：先做静态判别，再决定启动路径。判别失败要给出明确 UI 提示，而不是静默失败 —— 这是这类 App 最容易被源站改动搞崩的地方。

---

## 3. 客户端如何把本地服务变成"站点"

引用实现：FongMi `NodeConfigMapper.java` + `NodeRoute.java`。

### 3.1 拉站点目录

```
GET  http://127.0.0.1:<port>/config
```

响应若外层包了 `data`，下钻一层；**必须存在 `video` 对象**，否则报 "Node /config has no video object"。
遍历 `video.sites[]`：

- 跳过 `enable` 为 `false` / `0` / `"false"` / `"0"` 的站点；
- 计算该站点的**路由**：
  - 若站点带 `api` 字段：可能是完整 URL 或路径 → 归一化成 `/xxx`（`scheme://host` 部分丢弃）；
  - 否则用 `key`（去掉前缀 `nodejs_`）+ `type`（默认 `3`）→ `/spider/<key>/<type>`；
- 产出一个**标准 TVBox 站点**：

```json
{ "type": 3, "api": "node:/spider/<key>/<type>", "...其余站点字段原样保留" }
```

也就是：**用 `node:` 这个自定义 scheme 前缀，把 TVBox 的 `type:3`（自定义 spider）语义指向本地 Node 服务。**

### 3.2 路由拼接

`NodeRoute.append(api, endpoint)`：把 TVBox 风格的 endpoint 拼到路由后面，并保留原 query / 丢弃 fragment：

```
node:/spider/abc/3?x=1            +  /detail  →  node:/spider/abc/3/detail?x=1
node:/spider/abc/3                +  ?ac=detail → node:/spider/abc/3?ac=detail
node:/                          +  /home    →  node:/home
```

### 3.3 站点数据的字段约定（实测该 bundle 内部）

该 bundle 内部就把数据映射成 **TVBox / CatVod 的 vod 模型**，说明本地服务返回的就是这套字段：

```js
// 列表项：内部对象 → TVBox 字段
{ id, name, pic, remarks, tag, typeName, style }
  → { vod_id, vod_name, vod_pic, vod_remarks, vod_tag, type_name, style }

// 详情：sources[] → 播放串
{ name, urls:[...] }  →  vod_play_from: names.join('$$$')
                         vod_play_url : urls.join('$$$')
// 单集： `${name}$${id}`   多集： `k1$u1#k2$u2#...`
// 文件夹项： tag: "folder"（配合 action / style 表示目录）
```

分隔符是 TVBox 生态的通用约定：`$$$` 分播放源，`#` 分剧集，`$` 分「集名 / 地址」。
**实现播放器时第一件要写的工具函数就是这套解析器**（并且要处理全角转义：该 bundle 有把
`$ # @ | : & = ?` 转成全角 `＄ ＃ ＠ ｜ ： ＆ ＝ ？` 的编码函数，用于把 JSON 塞进 URL 参数，解析时要反向兼容）。

### 3.4 该源的实测路由表（用于建立测试基线）

```
/                                   "你好！"
/config                             ← 站点目录（App 首屏数据源）
/config/sites/list
/spider/bookhongguo/3               ← 站点路由实例（对应 <key>=bookhongguo）
/spider/manjuhongguo/3
/spider/wexYueYue/deviceId          ← 带自定义 endpoint 的站点路由
/proxy                              代理（防盗链 / 网盘直链中转）
/danmaku  ·  /v1/danmaku            弹幕
/api/v2/search/anime · /match · /search/episodes · /comment · /segmentcomment
                                    ← 弹弹play 风格弹幕接口（推断：集成弹弹play）
/voddetail/  ·  /vod/detail/  ·  /detail/
/settings/smartProxyLog · proxyMode · panPriority · autoDanmaku · showTranscode · livetovod/url
/website/api/*                      管理面板（见下）
/versioning  ·  /api/logs  ·  /home  ·  /init  ·  /search  ·  /play  ·  /support
```

`/website/api/*` 是该源自带的**网页管理面板后端**，实测包含：
`quark/cookie`、`pan189/cookie|account`、`pan115/cookie`、`pan123/account`、`new139/session|device`、
`guangya/token`、`thunder/sms/*`、`bili/cookie`、`emby/config`、`woniu4k/login`、
`credential/:provider/:field`、`backup/webdav/(backup|restore|test)`、`db`。

→ **含义**：网盘账号登录/凭据管理/备份都由源自己提供，宿主 App 可以把这套面板直接用 WebView 打开，
不必自己实现网盘协议。这是本项目最大的工作量节省点。

### 3.5 技术栈（推断，供排错参考）

该 bundle 由 esbuild 打包，内含 `fastify`（及 `light-my-request` / `toad-cache` / `proxy-addr` / `cookie`）、
`protobufjs`、`pako`、`fs-extra`、`web-streams-polyfill` 等，并调用这些 Node 内置模块：

```
node:crypto(40) util(14) stream(12) node:http(11) node:util(10) node:stream(10) node:events(10)
node:path(9) zlib(8) node:https(8) node:assert(8) fs(8) url(6) node:fs(5)
node:fs/promises(4) https(4) worker_threads(3) node:url(3) node:timers/promises(3)
node:diagnostics_channel(3) node:buffer(3) node:net(2) node:dns(2) node:async_hooks(2)
node:zlib(2) tty(2) os(2) tls(1) node:tls(1) node:stream/web(1) node:perf_hooks(1) module(1) dns/promises(1)
```

**这直接决定运行时选型的可行性**：任何"自己写 JS 引擎 + 手搓 shim"的方案，都要覆盖上表
（尤其 `crypto`、`fs/promises`、`http`/`https`、`net`、`tls`、`worker_threads`、`async_hooks`）。
结论：**不要手搓 shim，用真正的 Node 运行时。**

---

## 4. 配置契约（`index.config.js`）

引用实现：OKVideoMac `ContractBCompanionConfigParser` + `ContractBConfigBuilder`。

**核心安全原则：配置是"数据"，不是"代码"。宿主必须静态解析，绝不 eval。**

### 4.1 静态解析规则

- 在源码中按顺序找最早的赋值标记之一：
  `var index_config_default =` / `let …` / `const …` / `export default` / `module.exports =` / `exports.default =`
- 从标记之后解析一个**静态对象字面量**，接受的语法被刻意限制为：
  JSON 兼容字面量 + **JS 标识符键** + 注释 + 单引号字符串 + **尾逗号**
- 结果 ≤ 1 MB、深度 ≤ 64、值个数 ≤ 100,000，且必须是纯 JSON 树
- **实测该源**：`index.config.js` 正是 esbuild 的 CJS 产物，同时含
  `var index_config_default =` 与 `module.exports =` 两个标记 → 与上述解析器完全匹配。

### 4.2 配置内容（实测）

顶层是**一整套"提供者注册表" + 四个模块键**（共 28 个顶层键），实测如下。

**模块键**（用 `tools/probe/config-probe.mjs` 的 `--dump` 可自查）：

| 键 | 形状 | 说明 |
|---|---|---|
| `sites` | `{ list: [] }` | **实测为空数组** —— 站点目录不来自这里 |
| `pans` | `{ list: [...] }` | 网盘条目 |
| `alist` | `[{name, server}, …]` | 预置 2 台 AList 服务器（实测：`🐉神族九帝`、`💢repl`） |
| `color` | `[...]` | 主题色板（另有大量 Material-3 色：`primary`/`secondary`/`tertiary`/`surface`/`error`/`background`/`bgMask`… 各 6 组深浅色，供宿主 App 上色） |

> **关键结论（影响架构）**：发布出来的 `sites.list` 是**空的**。
> 也就是说**站点目录完全由运行时提供** —— 必须先把 bundle 跑起来，再 `GET /config`
> （或 `/config/sites/list`）才能拿到真正的站点表。想"只解析配置文件就拿到站点列表"是行不通的。

**提供者注册表（实测 24 个）** —— 这是这个源支持的全部网盘/资源后端，也是它 6.2 MB 体积的主要来源：

| 提供者 | 字段 | 类型 |
|---|---|---|
| `ali` | `token`, `token280` | 阿里云盘（凭据） |
| `quark` | `cookie` | 夸克（凭据） |
| `uc` | `cookie`, `token`, `refreshtoken`, `ut` | UC 网盘（凭据） |
| `baidu` | `cookie` | 百度网盘（凭据） |
| `y115` | `cookie` | 115 网盘（凭据） |
| `wuming` | `cookie` | 无茗（凭据） |
| `pan123ziyuan` | `cookie` | 123 网盘资源（凭据） |
| `guangyazhenying` | `cookie` | 光雅（凭据） |
| `panlian` | `account`, `password` | 盘链（凭据） |
| `bili` | `categories`, `cookie` | B 站（凭据） |
| `muou` `wogg` `zhizhen` `duoduo` `huban` `erxiao` `guanying` `qwmkv` `qiwei` `jutou` `leijing` | `url` | 站点/资源站（普通站点） |
| `tgsou` | `pic`, `count`, `url`, `channelUsername` | Telegram 搜索 |
| `tgchannel` | `{}` | Telegram 频道 |
| `douban` | `extend` | 豆瓣 |

**实测凭据值长度分布**（只看长度，不看内容）：`cookie` 6 个为空串、2 个长度为 6；
`token` 一个空、一个长度 12、一个长度 5；`password` 为空。
→ 发布出来的默认配置基本是**空占位**，但**字段 schema 本身就是"凭据容器"**，所以：
**bundle 运行后的 data 目录会写入账号凭据，绝不能随意外发或提交到仓库。**

引用实现里给"无伴生配置"的包准备的最小兼容配置长这样（可作为你的兜底模板）：

```json
{ "sites": {"list": []}, "pans": {"list": []},
  "danmu": {"urls": [], "autoPush": false}, "color": [] }
```

### 4.3 配置的合并语义

宿主持有**发布者默认值**和**用户已保存值**，深合并时**用户值永远优先**（包括"用户故意清空"）。
合并后的配置写进 data 目录再传给 bundle。另有"运行时投影键"概念：
`sites` / `video` / `read` / `comic` / `music` / `pan` / `danmaku` 这些键属于**运行时投影**，
计算"配置版本号"时应排除，否则每次请求里的分享缓存变化都会误判为"配置变了"。

---

## 5. 缓存、完整性与信任

引用实现：FongMi `NodeBundle.java`（Android）+ OKVideoMac（Apple）。

### 5.1 目录布局

```
<App 沙箱>/nodejs/bundles/<sha256(订阅URL)>/
├── active/                     ← 当前生效版本
│   ├── index.js
│   ├── index.js.md5            ← 标记文件（内容即 MD5）
│   ├── index.config.js
│   ├── index.config.js.md5
│   ├── <manifest>
│   └── .pending                ← 写入中标记
├── staging-<uuid>/             ← 下载暂存区
└── trusted-key.sha256          ← 信任钉扎（签名清单）
```

**按订阅 URL 的 sha256 建目录**，天然实现"多源隔离"。

### 5.2 流程

1. 取 `index.js.md5`（+ `index.config.js.md5`、可选 manifest）
2. 若已有 `active/` 且 **MD5 全部匹配**且签名验证通过 → **直接复用，不重复下载**（源站流量与启动速度的关键）
3. 否则下载到 `staging-<uuid>/`，逐个校验 MD5，**不匹配就报错丢弃**（不要"容错用旧的"）
4. 校验通过 → **原子提交**（目录 rename/切换），写 `.pending`
5. 启动时若发现 `.pending`，说明上次写入未完成 → 清理重建
6. **安全细节**：所有路径必须做 canonical 校验，确保落在 `<App 沙箱>/nodejs/` 内（防目录穿越）；
   失败时 `killProcess` 而不是"带病继续"

### 5.3 签名清单（进阶，M8 再做）

- manifest 内含 sha256 指纹；首次信任后写入 `trusted-key.sha256` **钉扎**
- 一旦某源使用过签名清单，**禁止降级为无签名版本**（"signed bundle cannot downgrade to unsigned"）
- 发布侧工具形态：`nodejs/tools/sign-bundle.mjs`

### 5.4 传输层策略

- 超时：连接 30s / 读 60s / 写 30s
- `followSslRedirects(false)`（**HTTPS 不自动跨跳**，防降级攻击；普通跳转照常）
- 大小上限：index 32 MB / config 2 MB / md5 1 KB / manifest 32 KB —— 实现时务必**流式限量**，
  别先下载再判断

---

## 6. 程序的生命周期与隔离

- Android 侧：bundle 跑在**独立 Service + 独立进程**里（`NodeService`），异常即 `killProcess`
- iOS 侧没有这个奢侈：**一个 App 进程内通常只能起一个 Node 实例**
  → 设计取舍：**单 Node 实例承载多个 bundle**（自研 bootstrap 支持循环 `require` 多个 bundle，
  每个 bundle 独立 data 目录 + 独立 bridge 端口 + 独立 `catServerFactory`），或"同一时刻只激活一个源"。
  **这一条必须在 M1/M2 用真机验证后再定架构。**
- bundle 崩溃/退出后要能自动重启（引用实现有 restart 排程与退避，并有"重启次数耗尽"状态）
- 宿主应定期健康检查本地服务（`/versioning` 或 `/config` 探活），失效则重启

---

## 7. 参考实现索引（写代码前先读这三个）

| 目标 | 仓库 | 文件 | 语言/平台 | 许可证注意 |
|---|---|---|---|---|
| **协议权威定义** | `fongmi/TV` 系（例：`15840213978a/fongmi-android6-main`） | `nodejs/src/main/assets/nodejs/bootstrap.js`、`nodejs/src/main/java/com/fongmi/nodejs/{NodeBundle,NodeService,NodeRoute,NodeConfigMapper,NodeManifest,NodeClient,NodeSpider}.java`、`tools/sign-bundle.mjs` | Java/JNI + libnode.so | FongMi 系多为 GPL-3.0 |
| **Apple 平台等价实现（首选蓝本）** | `yaolin-dev/OKVideoMac` | `Engines/Spider/{NodeBundleRuntimeService,NodeRuntimeContract,CatPawProtocol,NodeHTTPSpiderSiteProvider,QuickJSSpiderRuntime}.swift`、`Docs/ADR/0003-player-and-spider-runtimes.md` | Swift / SwiftUI / macOS | **GPL-3.0**（照抄则你的 App 也须 GPL） |
| **iOS 上的 Node 集成示例** | `JackLeeo/tvbox_flutter` | `ios/Runner/NodeJSManager.m`、`ios/Frameworks/NodeMobile.xcframework` | ObjC + NodeMobile + GCDWebServer | 需自行确认 |
| iOS Node 运行时 | `nodejs-mobile/nodejs-mobile`（社区活跃 fork）、`1Conan/nodejs-mobile`（"Full-fledged Node.js on iOS"） | NodeMobile.framework / xcframework | C++/ObjC | MIT 类 |

`JackLeeo/tvbox_flutter` 的 iOS 侧同时出现 `nativeServerPort` / `managementPort` / `spiderPort` 三个端口，
说明其做法是「NodeMobile 跑 bundle + GCDWebServer 做宿主侧 HTTP + 按用途分端口」，可直接借鉴该分层。

---

## 8. 多源实测对比：三种 bundle 家族

对四个订阅做了同一套静态体检（`tools/probe/config-probe.mjs`），结果分成三种家族：

| # | 订阅 | bundle MD5 | 体积 | 家族 |
|---|---|---|---|---|
| 0 | `cat.王二小放牛娃.top`（Basic Auth；302→OSS，伪装 JPEG） | `e5b9b774…` | 6.2 MB | **A 基础版**（24 提供者） |
| 1 | `9280.kstore.vip/cat`（直连，诚实 `text/javascript`） | `e5b9b774…` | 6.2 MB | **A 的镜像（与 #0 逐字节相同）** |
| 2 | `ghfast.top/…/Darklessing/catvod/…/lmentor`（GitHub 公开托管） | `f320a9ca…` | 9.2 MB | **B 全功能版** |
| 3 | `catpaw.douer.me`（Basic Auth，域名即"猫爪"） | `3ecc3964…` | 5.9 MB | **C 容器版** |

### 8.1 三个家族的结构差异

**A 基础版（6.2 MB / 24 提供者）**
阿里、夸克、UC、百度、115、无茗、123资源、光雅、盘链、B站 + 2 台 AList；配置只有 `sites / pans / alist / color`。

**B 全功能版（9.2 MB / 32 提供者）** —— 配置里多出这些**能力模块**，一个 bundle 就覆盖了传统上要分别实现的一大半功能：

| 模块 | 形状 | 含义 |
|---|---|---|
| `live` | `array(1)` | 直播源 |
| `emby` | `array(2)` | 预置 2 台 Emby 服务器当片源 |
| `cms` | `object{list}` | 苹果CMS 采集站 |
| `t4` / `catpaw` | `object{list}` | TVBox4 风格配置 / 猫爪配置 |
| `pansou` | `object{api_urls,channels,plugins,cloud_types,count,pancheck…}` | 盘搜聚合（10 个字段） |
| `webdav` | `array(3)` | 3 个 WebDAV 备份目标 |
| `danmu` | `{urls,format,autoPush,autoPushBlacklist,sourceStrategy}` | 弹幕 |
| `danmuBuiltin` | `{enabled,host,port,token,autoStart}` | **bundle 会自己起一个弹幕服务** |
| `bilibili` / `alist_tvbox` | `{cookie,classes}` / `{base_url,token,custom_classes}` | B 站 / AList |
| 新增网盘 | `pikpak`(`username,password,refresh_token,device_id,auth_client_id,user_id`)、`tianyi`、`pan123` | 凭据字段明显更多 |

**C 容器版（5.9 MB）** —— 配置里**没有**提供者注册表，只有一个二级 spider 加载器：

```json
{ "customSpiders": { "enabled": true, "dir": "", "urls": [], "strict": false,
    "allowOverride": false, "factoryTimeoutMs": 10000, "urlTimeoutMs": 10000 },
  "color": [ ... ] }
```

即：它**自己不定义站点**，而是从 `dir`（本地目录）或 `urls`（远程地址）**动态拉取并执行二级 JS spider**，
带 `factoryTimeoutMs` / `urlTimeoutMs` 超时与 `strict` / `allowOverride` 策略。默认 `urls: []` 为空，由使用者注入。

### 8.2 对架构的四条硬结论

1. **宿主契约是唯一的。** 四个源的 `catServerFactory` / `catDartServerPort` / `DEV_HTTP_PORT` **全部齐全**，
   全是 contract-b。→ `bootstrap.js` + `/msg` 桥实现一次就够；判别逻辑仍要保留（遇到 contract-a 要**明确报错**，不要猜）。
2. **源的身份 = bundle 的 MD5，不是 URL。**（#0 与 #1 逐字节相同，只有主机不同。）
   → **缓存键必须用 bundle MD5**，并维护"同一 MD5 的镜像 URL 列表"：换镜像不重下 6–9 MB，
   顺便得到镜像故障自动切换能力。
3. **config schema 会跨版本演化**（24 个提供者 → 32 个 + 新模块 → 只剩 `customSpiders`）。
   → 宿主**不得硬编码 schema**：按"发布者自有数据对象"处理（有界 JSON 校验 + 深合并 + 用户值优先），
   站点目录一律以**运行时 `/config`** 为准。**四个源的 `sites.list` 全部为空**，再次印证这一点。
4. **安全面比预想的大，两处必须写进设计：**
   - `danmuBuiltin{host,port,token,autoStart}` → bundle 会**再起一个本地服务**（**端口不止一个**）。
     宿主不能只记住 `serverStarted` 那一个地址，也不该假设只监听一个端口。
   - `customSpiders{dir,urls}` → bundle 会**远程拉取并执行二级 JS**，这些代码宿主无法审查。
   → 所以"只导入你信任的源"不是客套话；data 目录隔离、一键清空、凭据不入库是必需功能。

### 8.3 选源建议

- **优先用 B 类（GitHub 公开托管）**：`raw.githubusercontent.com` **实测可直连**（MD5 与经代理一致），
  有 commit 历史、可 diff、可回滚、可审计，比付费镜像站稳定得多。国内访问不畅时再加 `ghfast.top` 这类加速前缀。
- **A 类镜像站**（`9280.kstore.vip` 等）可当**同一 bundle 的备用镜像** —— MD5 相同，可直接互换。
- **C 类（`catpaw.douer.me`）是"容器"**，导入后还需额外的 spider 来源，属进阶用法。
- 注意 `9280.kstore.vip` 与 `cat.王二小放牛娃.top` 内容完全一致：**同一份包的不同门面**，
  所以"换源"有时只是换门面，MD5 相同就意味着不会带来新能力。

---

## 9. 验证状态

### 9.1 本次已确认（有实测数据支撑）

| 项 | 结论 |
|---|---|
| 包结构与完整性 | 四件套齐全，两个 MD5 均**校验通过**（`e5b9b774…` / `93f80717…`） |
| 传输特征 | Basic Auth 可用；302 跨域跳 OSS；**Content-Type 谎报 `image/jpeg`**；ETag 即 MD5 |
| 宿主契约 | 属 **contract-b（宿主集成型）**，三标记齐全 |
| 配置可静态解析 | 是（esbuild CJS 产物 + `var index_config_default =` 数据对象） |
| 配置结构 | 24 个提供者注册表 + `sites/pans/alist/color`；**`sites.list` 为空** |
| 凭据暴露面 | schema 含 cookie/token/password；默认值为空占位 |
| 客户端映射语义 | `node:/spider/<key>/<type>` 路由格式与站点字段（对照引用实现） |
| 多源一致性 | 4 个订阅（3 个家族）**全部**为 contract-b；`sites.list` **全部**为空；其中 2 个是同一 bundle 的逐字节镜像（详见 §8） |

### 9.2 待你实测确认（M0 剩余产出）

1. bundle 在**真 Node** 下能否 `require` 并 `start()`，`serverStarted` 是否按约回报
   —— 用 `tools/host/node-host.mjs --run`（干跑已验证到"启动前一步"）
2. `/config` 与 `/config/sites/list` 的真实响应体结构（`video.sites[]` 的确切字段）
3. `/spider/<key>/3` 期望的 endpoint 命名（`?ac=detail` / `/detail` / `/homeContent` …）—— 用 `--probe-routes` 实抓
4. `/proxy` 的参数约定（防盗链中转如何签名）
5. 首屏耗时、常驻内存、空闲 CPU（决定 iOS 端可行性）
6. 该源是否带签名清单（本次未探测到 manifest）
7. iOS 无 JIT 下 V8 的实际性能（M1 闸门）

> 上述第 2–5 项一旦抓完，写进 `docs/contract-notes.md` 并存为 `fixtures/`，
> iOS 侧的 TVBox 兼容层就可以"照着 fixture 写单测"，不用反复真跑 Node。
