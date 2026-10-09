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
