# 契约实测记录（D0 产出）

> 来源：`tools/host/node-host.mjs '<订阅地址>' --run --probe-routes`（2026-10-09，Windows + Node v24.21）
> 对三个源做了 **GET/POST × 两段式/三段式 × 多站点** 的完整探测，并用真实 id 走通了
> `home → category → detail → play`。**本文只写实测到的事实**，推断项单独标注。
> 产物：`fixtures/host/`（已 gitignore，含真实响应）；本文不写任何凭据。

---

## 1. 四件套与传输（三个源都一致）

| 项 | 实测 |
|---|---|
| `index.js.md5` | 32 位 hex，纯文本，可直接校验 |
| `index.js` | 6.49 MB（A 家族）/ 9.69 MB（B 家族）；**不需要看 Content-Type** |
| `index.config.js(.md5)` | 9,809 B（A）/ 14,851 B（B）+ 对应 md5 |
| Basic Auth | 源 URL 带 `user:pass` 时用 `Authorization: Basic …`；跳转到别的域后**不要继续带凭据** |
| 缓存键 | bundle MD5（A 家族两个镜像 MD5 完全相同 → 复用不重下） |

三个源（本次实测）：
| 源 | bundle MD5 | 站点数 |
|---|---|---|
| `9280.kstore.vip/cat`（A 家族） | `e5b9b774af06f3014f4cf0087cdf07a9` | **94 个站点** |
| `ghfast.top/…/lmentor`（B 家族） | `f320a9caef3193001857cae042c32024` | 42 个站点 |
| `catpaw.douer.me`（C 容器版） | `3ecc3964…` | 站点靠二级 spider 注入 |

---

## 2. 启动契约（原文档正确，实测复核）

```
node bootstrap.js <index.js> <index.config.js> <dataRoot> <bridgePort> <token>
```
- 启动日志里源自己会打一行 **`CatVodSpiderios listening on http://127.0.0.1:<port>`**（可用来做就绪判据）
- 通过 `POST http://127.0.0.1:<bridgePort>/msg`（`X-CatVod-Token`）回报 `serverStarted`
  ✓ 真机实测：iOS 上从 `node_start` 到 `serverStarted` **0.08 秒**（打桩源）
- 源还自带探活端点：**`GET /health`** → `{"ok":true,"name":"CatVodSpiderios"}`、**`GET /check`** → `{"run":true}`

---

## 3. 站点目录（`GET /config`）

- `GET /config` → 200，JSON，**A 家族 19,768 B / B 家族 10,923 B**
- 形状：`{ video: { sites: [ { key: "nodejs_xxx", name: "站点名", type: 3, … } ] } }`
- 映射规则（与 FongMi 一致，实测可用）：`key` 去掉 `nodejs_` 前缀 + `type`（=3）
  → **`api = node:/spider/<key>/3`**
- `GET /config/sites/list` → **404**（别用它，用 `/config`）

---

## 4. spider 接口：**POST + 三段式**（本次最大的修正）

> ❗ 旧文档里的 `GET /spider/<key>/3?ac=list` 之类**在真源上全是 404**。
> 真源注册的是 `POST /spider/<key>/<type>/<operation>`（源码里就是
> `s.post("/home", …) / s.post("/category", …) / s.post("/detail", …) / s.post("/play", …) / s.post("/search", …)`）。

| operation | 请求体（实测字段名） | 响应（实测） |
|---|---|---|
| `home` | `{}` | `{"class":[{"type_id","type_name"},…],"filters":{…}}`（A 家族 7 个分类） |
| `category` | `{"tid":"<分类>","pg":"1"}` | `{"page":1,"pagecount":n,"list":[{"vod_id","vod_name","vod_pic","vod_remarks"}]}`（单页 20–70 条） |
| `detail` | **`{"id":"<vod_id>"}`**（单数！`ids` 会返回空） | `{"list":[{vod_id,vod_name,vod_pic,vod_content,vod_year,vod_area,vod_actor,vod_director,vod_play_from,vod_play_url}]}` |
| `search` | `{"wd":"<关键词>"}`（源码里还兼容 `key`） | `{"list":[…同列表项…]}`；**站点没实现该方法时整个路由 404** |
| `play` | `{"flag":"<线路名>","id":"<集标识>"}` | `{"parse":0,"url":"…","header":{…}}`；解析失败时 **500 + 可读 message** |

**其它实测细节**

- 两段式（无 operation）与任何 `GET` 打这些路径 → fastify 404 `{"message":"Route GET:/spider/x/3 not found"}`
- `vod_id` 可能长得不像数字：`msearch:36452545`（豆瓣类聚合站）、`/voddetail/132423.html`（站点路径样式）
  → **必须原样回传**，不要做任何解析
- `vod_pic` 常是源自己的本地代理：`http://127.0.0.1:<port>/imageProxy?url=…`（宿主直接用即可）
- `vod_play_from` / `vod_play_url` 就是 `$$$` / `#` / `$` 三件套；**集标识常常是 base64 不透明 token**
  （例：`eyJwcm92aWRlcklkIjoicXVhcmsi…` = `{"providerId":"quark",…}`），play 时原样回传

---

## 5. 报错语义（排错时最省时间的三条）

| 现象 | 含义 |
|---|---|
| `404 {"message":"Route GET:/spider/… not found"}` | 路径/方法不对（**用 POST + 三段式**） |
| `404 {"message":"站点或操作不存在: xxx"}` | 站点存在但没实现该 operation（例如该站不支持搜索） |
| `500 {"message":"还没有配置夸克 Cookie，请先去配置中心登录夸克"}` | **源自己给的可读原因**：要先去源的配置中心登录网盘 |

另外源会通过桥主动推消息（实测抓到 `messageToDart toast` / `saveProfile` / `queryProfile` /
`openInternalWebview`）——`toast` 就是它想给用户看的提示，宿主应当展示出来（P5 做）。

---

## 6. 对实现的影响（已改）

1. **`NodeClient`（P4）改成 POST + 三段式**：`home / category / detail{id} / search{wd} / play{flag,id}`；
   `detail` 的字段名是 **`id`**。404 当作"该站点不支持此操作"而不是硬报错。
2. **`BrowseView` 先问 `home` 拿分类**（实测分类只在 home 里返回），再取第一个分类的第一页。
3. **打桩 bundle 改成同一套契约**，这样不导入真源也能端到端自测（`tools/host/p2-selftest.mjs` 已全绿）。
4. **播放前要登录网盘**：真源播放 500 时带的就是这句提示 → UI 要把 `message` 原样显示给用户
   （P5 的"配置中心"入口：源自己提供网页管理面板，用 WebView 打开 `/website` 即可）。

---

## 7. 还没测到 / 待确认

- C 容器版（`catpaw.douer.me`）的 spider 注入流程（本次未跑 `--run`）
- 防盗链：`play` 返回的 `header` 里到底带哪些头、是否需要 Referer（等真机播放时验证）
- 直播 / 弹幕 / 网盘登录后的完整播放链路（P6）
- 首屏性能基线：真源（6.5 MB bundle）在 iOS 无 JIT 下的启动耗时与常驻内存（等真机数据）

---

## 8. **`POST /init` 必须先调**（2026-10-10 补测，「有些源打不开」的根因）

> 用户反馈："有些源打不开，我在同类 APP 里能打开"（例：**虎斑|4K**）。
> 桌面复现 + 逐层排查后确认：**不是 App 的请求格式问题，是少调了一路 `init`。**

### 8.1 现象与实测

| 站点 | 只调 home（旧实现） | 先调 init 再 home（现在） |
|---|---|---|
| 虎斑\|4K（huban） | `500 {"message":"timeout of 15000ms exceeded"}`（15.0 s） | init 155 ms → home **90 ms** 正常返回分类/内容 |
| 多多\|4K（duoduo） | `500 {"message":"getaddrinfo ENOTFOUND tv.yydsys.top"}`（13 ms） | init 1.8 s（自动选中 `https://tv.yydsys.cc`）→ home 4.6 s |
| 玩偶\|4K（wogg） | 一直能用（**源码里写死的默认域名恰好还活着**） | init 1.7 s（选中 `https://www.wogg.live`）→ home 1.1 s |

### 8.2 原因（源码级）

- 真源给**每个站点**单独注册了 `POST /spider/<key>/<type>/init`（源码 `s.post("/init", t.init…)`），
  并把它和 `/home` `/category` … 并列注册；**`/home` 自己不保证先跑 init**。
- 一批"wex 系"站点（wogg / huajuan / muou / guanying / duoduo / **huban** / leijing / 123pan /
  shayang / jutou / qiwei / libvio / pianku）的上游域名是**运行期解析**的，候选顺序是：
  1. `index.config.js` 里该站点的 `url`（默认空字符串）
  2. 本机配置库 `wexfnwconfig.json` 里的 `<key>.url`（**嵌套路径**：`db.get('/huban/url')` → `data.huban.url`）
  3. 源的**远程配置**（它启动时会拉 `…/api.txt` → `ioswex.txt` → 一个伪装成 `.jpg` 的 JSON，
     内容是 `{"huban":["http://43.248.128.118:16969/"], "duoduo":["https://tv.yydsys.top/","https://tv.yydsys.cc/", …], …}`）
  4. 源码里**写死的默认域名**（会过期！huban 是 `http://103.217.192.130:16969`，duoduo 是 `https://tv.yydsys.top`）
  候选们会被**并发探测**（6 s 超时，取第一个有内容的），并把结果打一行
  `[FastSiteUrl] <key> selected <url>, probe=…ms`。
- 不调 init 时，`siteUrl` 停在**第 4 项**（写死的旧域名）——huban 的那个 IP 已经连不上（SYN 超时），
  duoduo 的 `tv.yydsys.top` 已经**没有 DNS 记录**，于是前端只看到"取不到内容 / 请求失败"。
- 顺带确认：`POST /spider/<key>/<type>/init` 返回 `{"siteUrl":"…"}`；**没有 init 的站点返回 404**，属正常。

### 8.3 对实现的影响（已改）

1. `NodeClient.initSite(site:)`：每个站点在**本次运行时会话里第一次用到之前**先调一次
   `/init`（幂等、失败撤销标记以便"重试"时再试），`home / category / detail / search / play` 入口都先经过它。
2. **源的报错文案必须显示给用户**：真源 500 时带 `message`（`timeout of 15000ms exceeded` 这种），
   以前被吞成"请求失败"，现在原样透出（`CatySourceError`），首页错误态写成"源返回：<原文>"。
3. 打桩 bundle 增加 `/init` 路由、`p2-selftest.mjs` 增加一条检查；`node-host.mjs` 串联探测也先调 init。
4. 新工具 `tools/probe/site-probe.mjs`（单站点探测）与 `tools/probe/src-session.mjs`（常驻会话），
   `tools/probe/bootstrap-trace.js`（把源的每一次出站请求打出来——这次就是靠它定位的）。

### 8.4 排错口诀（以后照这个顺序）

1. `node tools/probe/site-probe.mjs --sites <key>`：先看 `init` 的 `siteUrl` 是不是个"像样的域名"；
2. 再看 `[FastSiteUrl] … selected …` 那行；3 再看 home/category 的状态码与源给的 message。

---

## 9. 多源同进程 + 控制口（2026-10-10 实现，用户诉求：换源不要关 App）

> 背景：iOS 上 `node_start` 不可重入（一个进程只能起一次 Node），别人的 App 却能随手换源。
> 答案不是"重启 Node"，而是**让这一个 Node 进程同时跑多个 bundle**。

### 9.1 启动契约（新增用法 B，用法 A 保留兼容）

```
# A（老的单源形式，桌面工具/自检还在用）
node bootstrap.js <index.js> <index.config.js> <dataRoot> <bridgePort> <token>

# B（多源 + 控制口，App 用这个）
node bootstrap.js <spec.json>
spec.json = { "bridgePort": 12345, "token": "…",
              "sources": [ { "id": "…", "index": "…/index.js",
                             "config": "…/index.config.js", "dataRoot": "…" } ] }
```

bootstrap 现在做的事（在原来六条基础上扩了三条）：

1. `globalThis.catServerFactory` **按"正在启动的源"认领** server —— 每个源的 server 各自记在案，
   所以多源之间互不串台；每个源监听成功后单独回报 `sourceStarted {id, address}`
   （老的 `serverStarted` 照旧发一份，兼容桌面工具与自检屏）。
2. **监听自愈按源各自维护**（iOS 挂起会把 socket 收走 → 同端口原地重绑，每个源一份）。
3. **控制口**（我们自己的 HTTP 服务，只有下面三个动作，127.0.0.1 + `X-CatVod-Token`）：

| 方法 | 路径 | 作用 |
|---|---|---|
| GET | `/ctl/status` | 列出所有源与它们的地址/是否在监听 |
| POST | `/ctl/source` | **运行期启动一个源**（body = 一个 source spec）→ 返回它的服务地址 |
| POST | `/ctl/stop` | 关掉某个源的本地服务（代码与定时器要等 App 重启才彻底回收） |

启动成功后通过桥回报 `controlReady {address}`，宿主就知道控制口在哪。

### 9.2 两个坑（都踩过）

1. **同一个 `index.js` 只能 require 一次**（Node 模块缓存）→ 第二次 require 拿到同一个模块实例，
   而 bundle 的 `start()` 大多带"只跑一次"的保护 → **第二个源根本起不来**（表现为
   `start() 返回了，但始终没有监听任何端口`）。
   对策：这份文件已经加载过时，先把它**复制**到新源自己的数据目录（`.caty-bundle.index.js`）
   再用新路径加载 → 两个真正独立的实例（镜像源、运行期追加源都靠这条）。
2. **环境变量与 cwd 是进程级的**：每个源在**自己 start 之前**才设 `HOME` + `chdir(自己的 dataRoot)`；
   bundle 在 start 期间读 cwd/HOME 决定数据目录，之后就绑定了。

### 9.3 桌面实测（`tools/probe/multi-source-test.mjs`）

```
src1  /config 200  42 个站点   http://127.0.0.1:64435   （B 家族 9.7 MB bundle）
src2  /config 200  94 个站点   http://127.0.0.1:63552   （A 家族 6.5 MB bundle）
跨源取内容：虎斑|4K（在 src2 上） init 130ms → home 94ms  → 7 个分类
运行期追加源：POST /ctl/source → 200 366ms → 新源 http://127.0.0.1:63568
GET /ctl/status → 在跑 3 个：src1, src2, late-added
```

自检也覆盖了这条链路：`node tools/host/p2-selftest.mjs`（打桩 bundle 起两份 + 控制口追加一份）。

### 9.4 App 侧对应实现

- `NodeRuntime`：`launch(sources: [SourceSpec])` 写 `sources-spec.json` → `node_start`
  只带这一个参数；`@Published sourceBases`（sourceId → 本地地址）、`controlBase`、
  `sourceErrors`；`startSource(_:)` / `stopSource(_:)` 走控制口。
- `NodeClient`：不再只有 `serviceBase`，而是**按 sourceId 分发**（`setBase(_:for:)`），
  每个站点的请求都送到它所属那个源；`init` 缓存键 = 源地址 + 站点 key。
- `RuntimeCoordinator`：启动时把**所有已启用的源**一起拉起来（同一份 bundle 的镜像只起一份），
  站点目录是并集（每个站点带 `sourceId`）；设置页的开关**即时生效**——
  开→走 `/ctl/source` 现场启动，关→走 `/ctl/stop`。

---

## 10. 弹幕契约 + libmpv 内核（P6，2026-10-10）

### 10.1 弹幕（A 家族实测）

| 接口 | 说明 |
|---|---|
| `GET <源地址>/danmu/auto?name=<剧名>&episode=<集>` | 返回 **B 站风格 XML**：`<i><d p="时间,模式,字号,颜色,时间戳,池,用户,ID">文本</d>…</i>`。实测《庆余年》第 1 集 **3.2 MB / 数万条** → 解析必须放后台线程 |
| `GET <源地址>/danmusearch?keyword=<片名>` | 源自己的**弹幕搜索网页**（给 WebView 用） |
| `GET <源地址>/danmusearch/api/search?keyword=<片名>` | 搜索候选剧集（JSON：`data.danmuapi.data[{Id,Name,source,cover}]`） |
| `POST /msg {action:"getPlayInfo"}` | 源**等宿主回答**"现在播什么"：回复体要给 `{title, episodeName, flag, fileName}`；给不出来它会打 `[Danmaku] auto skipped: empty title` 直接跳过弹幕 |
| `POST /msg {action:"danmuPush", opt:{url}}` | 源把它构造好的弹幕地址推给宿主（宿主去取那个 URL 即可） |

宿主侧实现：`DanmakuService`（拉取+解析+缓存）、`DanmakuOverlay`（Canvas 按进度滚动，不建 View）、
`PlaybackContext`（播放页写、桥读）、控制条"弹"开关 + 设置里的总开关（默认关）。

### 10.2 libmpv 内核（MPVKit）

- 包：`mpvkit/MPVKit` 的 LGPL 预编译 `.xcframework`（28 个组件：libmpv + ffmpeg + libass + libplacebo + MoltenVK …）。
  下载脚本 `ios/scripts/fetch-mpvkit.sh`（清单与 sha256 来自它的 `Package.swift`），
  由 `project.yml` 的 `options.preGenCommand` 在生成工程前跑（**不用改 CI 文件**，绕开令牌缺 workflow 权限的限制）。
- ⚠️ **别用 SwiftPM 拉它**：28 个二进制包并发下载会稳定报 `already exists in file system`。
- ⚠️ 手接静态库必须自己补链接项：`-lc++`（MoltenVK/uchardet 要 C++ 运行时）、
  `VideoToolbox / AVFoundation / CoreAudio / CoreMedia / CoreVideo / CoreFoundation / Metal / Security / UIKit`、
  `-lz -lbz2 -liconv -lresolv -lexpat -lxml2`。
- 渲染：**CAMetalLayer 交给 mpv**（`mpv_set_option(mpv,"wid",…)` + `vo=gpu-next` + `gpu-api=vulkan` + `gpu-context=moltenvk`），
  mpv 负责解码后的缩放、字幕、HDR 色调映射 —— 宿主不写渲染循环。
  MoltenVK 两个 workaround（drawableSize 被设 1x1、HDR 的 wantsExtendedDynamicRangeContent 必须在主线程设）
  见 `MPVVideoLayer`；App 切后台 `vid=no`、回前台 `vid=auto`（否则回前台黑屏）。
- 内核选择：`PlaybackController`（自动 / 系统 / mpv）。自动模式下系统内核报错会自动切 mpv 重播同一个地址，
  并在界面给一条提示 + 一个"用 mpv 内核再试一次"的按钮。

### 10.3 源体检（`tools/probe/source-audit.mjs`）

对 5 个源 262 个站点跑过一轮（逐个 `init → home → category`，可选 `--pic-check` 真抓封面）：

| 源 | 站点 | 可用 | 空返回 | 报错 |
|---|---|---|---|---|
| 9280.kstore.vip（A 家族） | 94 | 79 | 8 | 7 |
| lmentor（B 家族） | 42 | 15 | 19 | 8 |
| smdl | 48 | 11 | 28 | 9 |
| XPTV | 20 | 3 | 4 | 13 |
| douer | 58 | 17 | 24 | 17 |

结论：**"打不开"绝大多数在源侧**，宿主无能为力，只能把原因说清楚：
- `getaddrinfo ENOTFOUND <域名>` → 站点上游域名已失效（源没更新）
- `请先在 Web 后台填写…/需要登录` → 要先去**源的配置中心**登录/填账号（App 已把这句话原样显示）
- `timeout of 10000/20000ms exceeded` → 上游太慢或被墙（XPTV 那批成人站基本都要梯子）
- `Cannot read properties of undefined` / `Dynamic spider handler not found` → 源自己的 bug
- `站点或操作不存在` / 无分类 → 有的站点是**搜索型**（"搜索|xxx"）或首页型，本来就没有分类列表
  （App 已改成提示"这是搜索型站点，去搜索页用它"，不再误报"取不到内容"）
