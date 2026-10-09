# Caty —— 项目说明（AI 助手每次开始工作前请先读完本文件）

## 这是什么

iPhone **自签自用**的「通用源」播放器。用户导入形如
`http(s)://user:pass@host/index.js.md5` 的订阅（MiraPlay / UZN / 羊壳 / 猫影视 / 猫爪 / JSTV /
PeekPili / 魔力云播 / 蚂蚁影视 共用同一套格式），App 下载 → 校验 → 在**内置 Node 运行时**里跑起来，
再映射成站点并播放。

## 用户是谁（决定你怎么沟通，非常重要）

**用户是小白，不写代码。** 分工固定为：

- **用户只做三件事**：① 执行你给的命令（要完整、可直接复制）② 把**报错原文整段**贴回来
  ③ 在手机上点一下并描述现象。
- **你负责**：所有代码、配置、脚本、文档、排错方案。代码要**整包可编译**，不要给片段让用户自己拼。
- 每次交付必须带四样：**目标 / 用户要做的操作 / 验收标准 / 卡住怎么办**。
- 不要问用户技术选型问题（他无法判断）；直接给方案 + 一句取舍理由。

## 环境事实

- 项目根目录：`D:\Zcode\Catys`（**这就是工作区根**，本文在根目录）
- 开发机：**Windows + Git Bash**。Git Bash 里盘符是 `/d/Zcode/Catys`
- Node v24 可用（供 `tools/` 下的验证工具使用）；`git` 2.55 与 `gh` 2.101 **已安装**（可建私有仓库并推送）
- 国内网络：直连 `github.com` 的 release 资源约 16 KB/s，`https://gh-proxy.com/<原URL>` 可到 ~1 MB/s（下载大文件用它）
- **iOS 编译必须有 macOS + Xcode** —— 用户**目前没有 Mac**，所以编译走 GitHub Actions（见事实 14 与 `docs/09`）。
  不要空等 Mac：继续做"不依赖编译"的事（写代码、桌面预演、打磨文档）
- 目标设备：用户的 iPhone，**iOS 27.0.1**，自签安装

## 必读文档（按此顺序）

| 顺序 | 文档 | 作用 |
|---|---|---|
| 1 | `docs/03-beginner-handbook.md` | **操作手册**。P0–P6 每步"你做什么/我做什么/怎么验收/卡住怎么办"；含 45 个文件清单、Info.plist、20 条报错速查表、验收清单、术语表 |
| 2 | `docs/00-protocol-spec.md` | **协议真相**（实测）：包结构、启动契约、`/msg` 桥、路由、配置、缓存、多源家族对比 |
| 3 | `docs/01-dev-plan.md` | 里程碑 M0–M8、最快路径日级排期、风险表、自签方案 |
| 4 | `docs/02-ui-spec.md` | UI 规格两部分：结构（8 屏版式/组件/字段对照）+ 细节（动效/手势/浅色/弹幕/文案/设置项全表） |
| 5 | `docs/05-data-model.md` | Swift 模型、SQLite schema、多源状态机、错误码、日志规范、设置键表 |
| 6 | `docs/04-conversation-log.md` | 决策记录（为什么这样设计），避免重复讨论已定的事 |
| — | `README.md` | 索引 + 当前状态 + 待办 |

## 关键技术事实（**不要重新推导**，都已实测）

1. **「源」不是配置，是一整个 Node.js 服务端程序**（实测 6.2 / 9.2 / 5.9 MB，esbuild 打包，
   内含 fastify、protobufjs、pako 与夸克/UC/阿里/百度/115/天翼/123/PikPak/Telegram/AList 的解析）。
   `index.js.md5` 只是"版本标记 + 校验文件"。
2. **源的身份 = bundle 的 MD5，不是 URL**（实测有两个源是同一份 bundle 的逐字节镜像）。
   → 缓存按 **bundle MD5** 建条目 + 维护镜像表；不要按 URL 存。
3. **四个源全部是 contract-b（宿主集成型）**：`catServerFactory` / `catDartServerPort` / `DEV_HTTP_PORT`
   三个标记齐全，必须实现完整 bootstrap 协议。
4. **启动契约**：
   ```
   node <bootstrap.js> <index.js 绝对路径> <index.config.js 绝对路径> <dataRoot> <bridgePort> <token>
   ```
   bootstrap 必须：注入 `globalThis.catServerFactory` 与 `catDartServerPort`；给 `http.request` 打补丁
   （发往 `POST 127.0.0.1:<bridgePort>/msg` 时自动带 `X-CatVod-Token`）；
   设 `CATVOD_DISABLE_AUTOSTART=1` / `HOST=127.0.0.1` / `PORT=0` / `HOME=dataRoot` 并 `chdir`；
   把 `server.listen` 强制为 `{host:'127.0.0.1', port:0, exclusive:true}`。
   bundle 必须 `export default { async start(config) {...} }`。
5. **回报**：bundle 通过 `POST /msg` 发 `{"action":"serverStarted","opt":{"address":"http://127.0.0.1:<port>",...}}`；
   失败发 `nodeError`。
6. **站点目录只能从运行时拿**：客户端 `GET /config` → `video.sites[]` → 映射成
   `{"type":3, "api":"node:/spider/<key>/<type>"}`。四个源的 `sites.list` **全部为空**（静态解析拿不到）。
7. **播放串分隔符**：`$$$` 分播放源、`#` 分集、`$` 分「集名/地址」；源内部还会把
   `$ # @ | : & = ?` 转成全角，解析时要反向兼容。
8. **iOS 27 用不了 TrollStore**（只覆盖 14.0–16.6.1 / 17.0 部分）→ **"无 JIT"是既定前提**。
   必做优化：`require('node:module').enableCompileCache?.(path.join(dataRoot, '.compile-cache'))`
   （已写进 `tools/host/bootstrap.js`）；再加"启动即预热 + 首屏用缓存渲染"。
9. **bundle 会另起本地服务并可能拉二级 JS**（`danmuBuiltin{host,port,token}`、
   `customSpiders{dir,urls}`）→ 不能假设只有 `serverStarted` 那一个端口；信任与隔离必须做进功能。
10. 参考实现（**2026-10 核实过，别再用旧结论**）：`FongMi/TV` **没有 iOS 版**，其 `nodejs/` 模块在别人的 fork 里
    （Android，Java+libnode，对 iOS 无参考价值）；Apple 平台看 `yaolin-dev/OKVideoMac`（macOS，**GPL-3.0**，
    只可参考信任/缓存/重启状态机的设计，运行时集成方式不适用）、`JackLeeo/tvbox_flutter` 的
    `ios/Runner/NodeJSManager.m`（ObjC + NodeMobile + GCDWebServer）、**`1970905901/Y-Player`**
    （Swift 的 `CatVodNode` 模块，与 Caty 同域，最值得照抄）、`digidem/comapeo-core-react-native`
    （Node 24 真机验证案例）。
11. **iOS 运行时选型已定：`digidem/nodejs-mobile` 的 `v24.20.0-0`（lite）**，不是官方 NodeMobile。
    原因：官方线停在 Node 18.20.4，而 iOS 无 JIT 时 V8 **没有 WebAssembly** → `fetch()`（undici）直接是坏的，
    源里到处在用；Node 24 线把 polywasm 编进运行时，且支持编译缓存。
    产物：`nodejs-mobile-ios-lite-24.20.0-0.zip` → 里面的 `NodeMobile.xcframework`（iOS 14+，**动态库**，需 Embed & Sign）。
    **已下载核验（2026-10-09）**：包内 Node **v24.20.0**、含 `polywasm` 与 `UNDICI_NO_WASM_SIMD`、
    Mach-O arm64 动态库（device 切片 45.8 MB）、`MinimumOSVersion 14.0`、Xcode 26 / iOS 26.5 SDK 构建；
    **模拟器片只有 arm64**（没有 Intel 模拟器片）；sha256 = `991283d8579eee225142da2bf4a897dd7d831e8b5a496a1f247fca665bc1d705`。
    国内直连 GitHub release 约 16 KB/s，用 `https://gh-proxy.com/<原URL>` 可到 ~1 MB/s。
12. **iOS 上 `node_start` 不可重入**：一个进程只能起一个 Node 实例，也没有 `child_process`；Node 挂了只能重启 App。
    → 状态机里的"自动退避重启（1s/3s/9s）"在 iOS 上改为"进程级重启"，多源先用"同一时刻只激活一个源"
    （docs/00 §6 的多 bundle 方案待 M1 真机数据再定）。
13. **编译缓存的两个坑**：① 必须带 `NODE_COMPILE_CACHE_PORTABLE=1`（iOS 容器路径含 UUID，不加会静默全 miss）；
    ② `NODE_COMPILE_CACHE` 必须在 `node_start` **之前**由宿主 `setenv`（环境变量只在 Environment 创建时读一次）。
    另：iOS 上要按机型设 `--max-old-space-size`（App 侧按物理内存 1/3、封顶 1.5 GB 自动算）。
14. **没有 Mac 时的编译通路（当前主路径）**：`.github/workflows/build-ipa.yml` 借 GitHub 的 macOS runner →
    自动下载 NodeMobile（校验 sha256）→ `xcodegen generate`（工程描述在 `ios/project.yml`）→
    `xcodebuild -scheme Caty -derivedDataPath build … CODE_SIGNING_ALLOWED=NO` → 产出 `Caty-unsigned.ipa`
    → Windows 上用 **Sideloadly** 签名装机。**已跑通**：真机装上、Node 跑起来了。
    **不要把 `NodeMobile.xcframework` 或 `.xcodeproj` 提交进仓库**（100 MB+、国内推送极慢；`.gitignore` 已挡）。
    ⚠️ 两个已踩过的坑：① `-derivedDataPath` 必须配 `-scheme`，不能用 `-target`
    （报 `The flag -scheme … is required when specifying -derivedDataPath`）；
    ② 不要给编译步骤加 `continue-on-error: true` —— 它会把失败伪装成"成功"，让人误判。
15. **仓库与两个 GitHub 限制（2026-10-09 实测，别踩第二次）**：
    - 仓库：`https://github.com/teng662858/caty`（**已公开 PUBLIC** —— 用户选择方案 A，
      目的是让 Actions 免费跑 macOS；私有仓库会因免费额度用尽被计费拦截）。
    - **令牌缺 `workflow` 权限** → `git push` 遇到 `.github/workflows/**` 一律被拒
      （`refusing to allow an OAuth App to create or update workflow … without workflow scope`），
      Contents API 也不行（返回 404 掩码）。→ 该目录已加进 `.gitignore`；改 CI 只能
      **用 ZCode 内置浏览器（已登录 GitHub）在网页界面创建/编辑**，或先让用户执行一次
      `gh auth refresh -h github.com -s workflow`。
    - **网页新建文件的坑**：`/new/<分支>/<完整路径>` 会把最后一段当**目录**，于是建出
      `.github/workflows/ios.yml/ios.yml`（多一层，GitHub 认不出是工作流）。
      要建文件请用目录形式 `/new/main/.github/workflows`，再在「File name」里只填文件名。
    - 遗留小尾巴：那个误建的 `.github/workflows/ios.yml/ios.yml` 还在，无害，得空清理。
16. **spider 接口 = POST + 三段式**（2026-10-09 三源实测，**推翻了早期的 `GET ?ac=` 猜测**）：
    `POST /spider/<key>/3/<op>`，参数走 JSON body：
    `home {}` → `{class,filters}`；`category {tid,pg}` → `{page,pagecount,list}`；
    `detail {id}`（**单数 id**，用 `ids` 返回空）；`search {wd}`（站点没实现则整条路由 404）；
    `play {flag,id}` → `{url,header,parse}`，失败时 **500 + 可读 message**（如"还没有配置夸克 Cookie…"）。
    两段式与任何 GET 打到这些路径都是 fastify 404；站点目录仍走 `GET /config`。详见 `docs/contract-notes.md`。
    源还会通过桥主动推消息（实测 `toast` / `saveProfile` / `queryProfile` / `openInternalWebview`）——
    `toast` 就是它想给用户看的提示，宿主应当展示。
17. **iOS 挂起 App 会回收监听 socket**（真机实测：启动 85 秒后宿主请求报"无法连接服务器"，
    而 `node_start` 并未返回）→ `bootstrap.js` 已加"监听自愈"：每 10 秒自连一次自己，
    掉线就在**同一端口**重建 server 并重新回报 `serverStarted`（换端口会让宿主手里的旧地址失效）。

## 铁律（不可违反）

1. **只做容器**：不内置、不打包、不分发任何内容源；不实现 VIP 解析或 DRM 绕过；**只自签自用**，
   不要建议上架、分发或收费。
2. **脱敏**：写进文件的日志/文档/示例里，`cookie` / `token` / `password` 一律写
   `<redacted len=n>`，URL 里的 userinfo 一律写 `<user>:***@`。
3. **用户的源地址带密码，不要写进任何项目文件**；需要时向用户索取（他手上有）。
4. **代码整包给**（能编译的完整文件 / 完整命令），不要给需要他拼装的片段。
5. **每步给验收标准**，并说明失败时的排查方向。
6. **不要重写已定的设计**：先读 `docs/00` 与 `docs/04`，有异议先说明理由再改。
7. 报错排查时，**必须要求用户贴原文**（不要接受"报错了"这类转述）。

## 当前进度与下一步

进度以 `README.md` 的「当前状态」为准。**用户是小白、没有 Mac、目标是自己手机上能用的播放器。**

**已完成到"日常可用"**：
- 协议实测（`docs/contract-notes.md`，POST + 三段式）→ `ios/` 30 个 Swift 文件（P2/P3/P4/P5 全交付）
- **零 Mac 通路跑通**：GitHub Actions 出未签名 ipa → Windows Sideloadly 装机（真机 iOS 27.0.1）
- **能播已完成**：真源 94 站点、启动 0.78s、缓存命中、直链站与网盘站（夸克）都能出画面
- **P5 已完成**：4 tab（首页/片库/搜索/设置）、海报墙、分类+**按分类显示的筛选**、详情（收藏/续播/选集）、
  播放器（进度记忆/倍速/上下集/全屏弹出）、片库（收藏+历史）、设置（配置中心/诊断/清缓存）
- 真机联调修过的坑：桥连接生命周期、桥与 bundle 的监听自愈、跳集（导航栈堆积→改全屏弹出）、
  海报不整齐、SwiftUI 表达式过深导致类型检查超时

**下一步（P6 打磨，用户报什么先修什么）**：
- 后台音频、播放手势（亮度/音量/快进）、动效、浅色模式
- **libmpv**（mkv/4K 2160p/字幕/软解）——用户已遇到"2160p mkv 播不了"
- 直播 EPG、弹幕渲染、iPad

**标准出包流程（新会话照这个走，用户只需装包）**：
```bash
# 1) 改代码后：自查 → 提交 → 推送（推送会自动触发云端编译）
cd /d/Zcode/Catys && node tools/check-swift-heuristics.mjs ios
git add -A && git commit -m "说明" && git push
# 2) 盯 CI（约 1–3 分钟）
gh run list --limit 1 && gh run view <id> --json status,conclusion
# 3) 成功就下载 ipa（失败看 --log-failed 的 error: 行）
rm -rf dist/ipa dist/Caty-unsigned.ipa
gh run download <id> -n Caty-unsigned-ipa -D dist/ipa && cp dist/ipa/Caty-unsigned.ipa dist/Caty-unsigned.ipa
# 4) 告诉用户：Sideloadly 拖 dist/Caty-unsigned.ipa 重装（覆盖安装，数据不丢）
```
⚠️ 两个已踩的坑：① SwiftUI 视图表达式别太深（拆小函数，否则报
"unable to type-check this expression in reasonable time"）；② workflow 文件只能走网页界面改（见事实 15）。

## 工具（均已验证，可直接用）

| 工具 | 作用 | 安全 |
|---|---|---|
| `tools/probe/config-probe.mjs` | 源包体检：下载、MD5 校验、跳转链、MIME 伪装、契约判别、**静态**解析配置与提供者注册表、`--dump` 脱敏查看子树 | ✅ 不执行任何下载到的 JS |
| `tools/host/node-host.mjs` | 桌面**参考宿主**，等价 FongMi 的 `NodeBundle`+`NodeService`+`NodeConfigMapper`+`NodeRoute` | ⚠️ **默认干跑**；加 `--run` 才执行第三方代码，执行前必须提醒用户 |
| `tools/export-session.mjs` | 把 ZCode 会话导出成 Markdown（只读 `~/.zcode/cli/db/db.sqlite`，自动脱敏）。用户说"把对话存下来"时用它 | ✅ 只读 |
| `tools/host/bootstrap.js` | **启动契约**实现（含编译缓存优化）—— 已逐字节同步到 `ios/Resources/bootstrap.js`，**两边必须一致** | 同 bootstrap 用途 |
| `tools/host/p2-selftest.mjs` | **P2 链路桌面预演**：用 iOS 那份 `bootstrap.js` + 打桩 bundle 跑通 `serverStarted → /config → 站点映射` | ✅ 不下载、不执行第三方代码 |
| `tools/check-swift-heuristics.mjs` | Swift 粗略自查（Windows 无编译器时兜底）：括号平衡 / 中文引号 / 冲突标记 / 行数总览 | ✅ 只读 |
| `tools/make-ios-package.mjs` | 一键重打包 `dist/Caty-P2P3-代码包.zip`（改完 `ios/` 后必须重跑，打前自动自查+预演） | ✅ 只读源码 |

`host-data/`（bundle 缓存）与 `fixtures/`（探测产物）已 gitignore，体积约 37 MB，**不要删**。

## 不要做的事

- 不要重新发明协议（先读 `docs/00`）。
- 不要手写 JS 引擎 shim 替代 Node（bundle 用到 27–33 个 Node 内置模块，含 `crypto`、`worker_threads`、`net`）。
- 不要自研网盘解析（源里已经实现了）、不要自研爬虫。
- 不要在无 JIT 问题上"试试看再说"——必须按既定方案（编译缓存 + 预热 + 缓存渲染）实施，
  并把实测数字记下来。
