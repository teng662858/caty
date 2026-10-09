# 数据模型 · 状态机 · 错误 · 日志 · 设置键

> 施工依据。与 [02-ui-spec.md](02-ui-spec.md) 配合使用：**02 管"看到什么"，本文管"数据长什么样、状态怎么流转、出错怎么办"**。
> 实现时如与代码有出入，以代码为准并回来更新本文。

---

## 1. Swift 数据模型（P2–P4 直接落地）

```swift
// ── 源 ────────────────────────────────────────────────────────────
struct SourceRecord: Codable, Identifiable {
    var id: String            // sha256(规范化后的订阅URL，去掉 userinfo)
    var displayName: String   // 用户可改，默认取 bundle 里的站点名或域名
    var url: String           // 订阅地址（含 userinfo，仅存 Keychain 引用）
    var enabled: Bool         // 启用开关
    var mirrors: [String]     // 同一 bundle MD5 的其它镜像 URL
    var lastIndexMD5: String  // 最近一次成功的 bundle MD5
    var lastConfigMD5: String?
    var lastCheckedAt: Date
    var lastError: String?
    var createdAt: Date
}

// ── bundle 版本（一个源可保留多版，用于回滚）──────────────────────
struct BundleVersion {
    var sourceId: String
    var indexMD5: String      // 主键之一
    var configMD5: String?
    var bytes: Int
    var contractKind: String  // "contract-b" / "contract-a"
    var fetchedAt: Date
    var isActive: Bool
}

// ── 站点（由运行时 /config 映射而来，不落库，内存缓存）─────────────
struct SiteInfo: Codable, Identifiable {
    var key: String           // 站点 key（去掉 nodejs_ 前缀后）
    var name: String
    var type: Int             // 固定 3（自定义 spider）
    var api: String           // "node:/spider/<key>/<type>"
    var searchable: Bool
    var enabled: Bool
    var group: String?
    var ext: String?
    var sourceId: String      // 来自哪个源
}

// ── 影视条目 ─────────────────────────────────────────────────────
struct VodItem: Codable, Identifiable {
    var id: String            // vod_id
    var name: String          // vod_name
    var pic: String?          // vod_pic
    var remarks: String?      // vod_remarks
    var tag: String?          // vod_tag（"folder" 表示目录）
    var typeName: String?     // type_name
    var year: String?
    var siteKey: String
    var sourceId: String      // 用于「换源播放」和来源角标
}

struct VodDetail: Codable {
    var item: VodItem
    var content: String?      // vod_content
    var actor: String?        // vod_actor
    var director: String?
    var area: String?
    var playFrom: [String]    // vod_play_from 按 $$$ 拆
    var playUrls: [[Episode]] // vod_play_url 按 $$$ 再按 # 拆
}

struct Episode: Codable, Identifiable {
    var id: String { "\(name)|\(url)" }
    var name: String          // 集名（"第01集"）
    var url: String           // 播放地址或可解析的标识
    var watched: Bool
    var progress: Double?     // 0–1，来自历史
}

// ── 本地库 ───────────────────────────────────────────────────────
struct FavoriteRecord: Codable, Identifiable {
    var id: String            // "\(sourceId)|\(siteKey)|\(vodId)"
    var item: VodItem
    var addedAt: Date
}

struct HistoryRecord: Codable, Identifiable {
    var id: String            // 同 FavoriteRecord.id
    var item: VodItem
    var episodeIndex: Int
    var episodeName: String
    var positionSec: Double   // 断点
    var durationSec: Double
    var updatedAt: Date
}

struct SearchHistoryRecord: Codable, Identifiable {
    var id: String
    var keyword: String
    var searchedAt: Date
}

// ── 运行时状态 ───────────────────────────────────────────────────
struct RuntimeStatus {
    var sourceId: String
    var state: SourceState
    var baseURL: URL?         // "http://127.0.0.1:54321"
    var nodeVersion: String?
    var memoryMB: Double?
    var startedAt: Date?
    var lastError: String?
}
```

**规范**：所有网络/JSON 字段一律 `String?` 宽松解析（源返回的类型会变），
取用时用 `??` 兜底；**不要**用非可选类型解析源数据。

---

## 2. 本地数据库（GRDB / SQLite）

> 📌 **实施时点（2026-10-09 起）**：P3 的**源清单先用 JSON 文件**（`sources/registry.json`，
> 见 `ios/Sources/Runtime/SourceRecord.swift` 的 `SourceStore`），**GRDB 到 P5 才引入** ——
> 收藏/历史/搜索历史那时才需要表结构，而 P3/P4 阶段"少一个 SPM 依赖 = 少一个报错来源"。
> 迁移方式：把那份 JSON 一次性导入下面的 `source` / `bundle_version` 两张表。
> 决策理由见 docs/04 第 5 轮 ADR 10。

```sql
CREATE TABLE source (
  id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  url TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  mirrors TEXT NOT NULL DEFAULT '[]',   -- JSON 数组
  last_index_md5 TEXT,
  last_config_md5 TEXT,
  last_checked_at REAL,
  last_error TEXT,
  created_at REAL NOT NULL
);

CREATE TABLE bundle_version (
  source_id TEXT NOT NULL,
  index_md5 TEXT NOT NULL,
  config_md5 TEXT,
  bytes INTEGER NOT NULL,
  contract_kind TEXT,
  fetched_at REAL NOT NULL,
  is_active INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (source_id, index_md5)
);

CREATE TABLE favorite (
  id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL, site_key TEXT NOT NULL, vod_id TEXT NOT NULL,
  name TEXT NOT NULL, pic TEXT, remarks TEXT, year TEXT,
  added_at REAL NOT NULL
);
CREATE INDEX idx_favorite_added ON favorite(added_at DESC);

CREATE TABLE history (
  id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL, site_key TEXT NOT NULL, vod_id TEXT NOT NULL,
  name TEXT NOT NULL, pic TEXT, remarks TEXT,
  episode_index INTEGER NOT NULL DEFAULT 0,
  episode_name TEXT,
  position_sec REAL NOT NULL DEFAULT 0,
  duration_sec REAL NOT NULL DEFAULT 0,
  updated_at REAL NOT NULL
);
CREATE INDEX idx_history_updated ON history(updated_at DESC);

CREATE TABLE search_history (
  id TEXT PRIMARY KEY, keyword TEXT NOT NULL, searched_at REAL NOT NULL
);

CREATE TABLE setting (            -- 键值表，兼容枚举/数字/布尔/字符串
  key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at REAL NOT NULL
);
```

**规范**
- 迁移用 GRDB `DatabaseMigrator`，每次改 schema 加一个 migration，**不删库**。
- 删除源时：级联删 `bundle_version`，**保留** `favorite`/`history`（换源后仍能找到片子，只是播不了再提示换源）。
- 图片不落 SQLite，走 URLCache（磁盘 500 MB，内存 50 MB，LRU 淘汰）。

---

## 3. 多源状态机

```swift
enum SourceState: String {
    case idle          // 已导入，未启动
    case checking      // 正在比对 MD5
    case downloading   // 下载中（带进度）
    case verifying     // MD5 校验中
    case launching     // node_start 已调用，等 serverStarted
    case ready         // 可用
    case updating      // 后台换版中（旧版仍可用）
    case failed        // 失败（可重试）
    case unsupported   // 契约不支持（不可重试，需换源）
}
```

| 当前 | 事件 | 下一个 | 界面表现 |
|---|---|---|---|
| idle | 启动 | checking | 状态点灰 |
| checking | MD5 未变 | launching | — |
| checking | MD5 变化 | downloading | 进度条 |
| downloading | 完成 | verifying | — |
| verifying | 通过 | launching | — |
| verifying | 不匹配 | failed | 错误条「MD5 不匹配」 |
| launching | 收到 serverStarted | ready | 绿点 + 地址 |
| launching | 超时 / nodeError | failed | 错误条 + 重试 |
| launching | 契约标记不完整 | unsupported | 「不支持的源契约」 |
| ready | 收到新 MD5 | updating | 顶部小字「更新中」 |
| updating | 切换成功 | ready | toast「源已更新到新版本」 |
| 任意 | 进程退出 | failed | **iOS 上改为「进程级重启」**：`node_start` 不可重入（一个进程只能起一个 Node），界面给明确提示让用户重开 App |

**规则**：`updating` 期间继续用旧版本服务，**不允许出现"更新中不能用"的窗口**。

> ⚠️ **iOS 实施修正（2026-10-09，见 docs/04 第 5 轮 / ADR 11–12）**：
> `node_start` 在 iOS 上**不可重入**，进程内既停不掉也起不了第二个 Node → 原"自动退避重启（1s/3s/9s）"
> 改为**进程级重启**（提示用户重开 App，日志跨会话保留）。
> 多源策略先用「同一时刻只激活一个源」；"单 Node 实例承载多 bundle"待 M1 真机数据再定（docs/00 §6）。

---

## 4. 错误码表

```swift
enum CatyError: String, Error {
    case noSource, downloadFailed, md5Mismatch, unsupportedContract
    case runtimeLaunchFailed, bridgeTimeout, configMissing, configInvalid
    case siteEmpty, requestTimeout, requestFailed, decodeFailed
    case playbackUnsupported, proxyRequired, offline, runtimeDown
}
```

| 错误 | 用户文案（见 02 §16.3） | 可重试 | 日志级别 |
|---|---|---|---|
| `noSource` | 还没有导入源 | — | info |
| `downloadFailed` | 下载失败，请检查网络或换镜像 | ✅ | warn |
| `md5Mismatch` | 校验不通过，已丢弃本次内容 | ✅ | error |
| `unsupportedContract` | 不支持的源契约（缺少宿主标记） | ❌ | error |
| `runtimeLaunchFailed` | 源启动失败：{message} | ✅ | error |
| `bridgeTimeout` | 运行时准备中（已 {n}s） | ✅ | warn |
| `configMissing` | 源没有返回站点目录 | ✅ | warn |
| `configInvalid` | 源返回的配置无法解析 | ❌ | error |
| `siteEmpty` | 这个源暂时没有可用站点 | ✅ | warn |
| `requestTimeout` | {站点名} 响应超时 | ✅ | warn |
| `requestFailed` | {站点名} 请求失败（{code}） | ✅ | warn |
| `decodeFailed` | {站点名} 返回了意外数据 → 展开详情 | ❌ | warn |
| `playbackUnsupported` | 这个格式当前内核播不了 → 换线路 | ❌ | info |
| `proxyRequired` | 需要中转代理（防盗链） | ✅ | info |
| `offline` | 已离线 · 显示缓存内容 | — | info |
| `runtimeDown` | 运行时未运行 → 重启运行时 | ✅ | warn |

**规则**：`decodeFailed` 的「展开详情」必须给出**原始响应片段（截断 2KB）+ 请求路径**，
方便你直接贴给源作者 —— 这是最省时间的排错路径。

---

## 5. 日志规范

- **分级**：`verbose` / `debug` / `info` / `warn` / `error`（默认记录 `info` 及以上）
- **格式**：`[HH:mm:ss.SSS][级别][模块] 内容`，模块取 `runtime` / `bridge` / `store` / `net` / `site` / `player` / `ui`
- **缓冲**：内存环形缓冲 2000 条 + 磁盘滚动 5 个文件 × 2 MB
- **必须记录的事件**
  - 源：MD5 比对结果、下载体积与耗时、校验结果、契约判别结果、启动耗时、端口
  - 桥：`serverStarted` / `nodeError`（**原文**）
  - 站点：每次请求的路径、状态码、耗时、响应前 200 字符
  - 播放：内核、格式、起播耗时、失败原因
- **脱敏（硬要求）**：`cookie` / `token` / `refresh_token` / `password` 一律写 `<redacted len=n>`；
  URL 里的 userinfo 一律写 `<user>:***@`。**日志可以随便发给别人**，这是设计目标。
- **导出**：`.txt`，开头附环境头（App 版本、iOS 版本、机型、运行时版本、每个源的 MD5 与契约类型、当前设置快照）。

---

## 6. 设置持久化键表（`setting` 表，走同一个 key-value 接口）

| key | 类型 | 默认 | 说明 |
|---|---|---|---|
| `source.autoCheckOnLaunch` | Bool | true | 启动时检查更新 |
| `source.checkIntervalHours` | Int | 6 | 检查间隔 |
| `player.hardwareDecode` | Bool | true | 硬解（libmpv） |
| `player.defaultRate` | Double | 1.0 | 0.5–2.0 |
| `player.rememberProgress` | Bool | true | 记忆进度 |
| `player.skipIntro` | Bool | false | 跳过片头 |
| `player.skipIntroSeconds` | Double | 90 | 0–120 |
| `player.skipOutro` | Bool | false | 跳过片尾 |
| `player.skipOutroSeconds` | Double | 120 | 0–120 |
| `player.backgroundAudio` | Bool | true | 后台音频 |
| `player.subtitleScale` | Double | 1.0 | 0.8–1.6 |
| `danmaku.enabled` | Bool | true | 默认开启 |
| `danmaku.opacity` | Double | 0.55 | 0.2–1.0 |
| `danmaku.fontScale` | Double | 1.0 | 0.8–1.4 |
| `danmaku.speedSeconds` | Double | 8 | 6–12 |
| `danmaku.area` | String | `full` | `full` / `topHalf` |
| `danmaku.blockKeywords` | String | `""` | 逗号分隔 |
| `ui.appearance` | String | `dark` | `system` / `dark` / `light` |
| `ui.accentColor` | String | `""` | 空 = 用源的 `color[0]` |
| `ui.gridColumns` | Int | 3 | 2 / 3 / 4 |
| `ui.showRemarksBadge` | Bool | true | 显示备注角标 |

---

## 7. 版本与备份

| 项 | 规则 |
|---|---|
| App 版本 | `MAJOR.MINOR.PATCH`（当前从 `0.1.0` 起） |
| bundle 版本 | 展示为 MD5 前 12 位，如 `f320a9caef31` |
| 数据导出 | 单个 JSON：`{sources(不含凭据), favorites, history, settings, exportedAt}` |
| 数据导入 | 合并策略：源按 id 去重（保留本地 enabled）；收藏/历史按 id 去重（保留较新的 `updatedAt`） |
| **不导出** | 凭据（cookie/token）、bundle 本体、图片缓存 |
| 凭据存放 | Keychain（`kSecClassGenericPassword`，service = `com.<you>.caty.source`） |
| 覆盖安装（自签重装） | 数据保留（沙箱不删）；**"删除 App"会清空全部数据**，重要内容先导出 |

---

## 8. 明确不做（v1 非目标）

| 不做 | 原因 |
|---|---|
| 多语言（仅简体中文） | 自用 |
| iPad 专门优化 | 已确认只做 iPhone |
| 下载 / 离线缓存 | 网盘源本身就是在线直链，收益低 |
| 多用户 / 多设备同步 | 自用；备份靠导出 JSON |
| 自研网盘解析（夸克/UC/天翼…） | 源已经做了，重复造轮子 |
| VIP 解析 / DRM 绕过 | 不做，见 README 合规声明 |
| 自研 spider 规则引擎（drpy 语法） | v1 只用 Node bundle；QuickJS 源排在 M6 之后 |
