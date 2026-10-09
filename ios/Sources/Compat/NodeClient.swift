//
//  NodeClient.swift
//  访问本地 Node 服务的客户端
//
//  ⚠️ 契约是 **M0 实测**出来的（tools/host/node-host.mjs --run --probe-routes），不是猜的：
//     GET  /config                    站点目录（唯一一个 GET）
//     POST /spider/<key>/3/init       body {}                    → {siteUrl:"…"}（**每个操作的先决条件**）
//     POST /spider/<key>/3/home       body {}                    → {class:[{type_id,type_name}], filters}
//     POST /spider/<key>/3/category   body {tid, pg}             → {page, pagecount, list:[vod_*]}
//     POST /spider/<key>/3/detail     body {id: "<vod_id>"}      → {list:[vod_* 含 vod_play_from/url]}
//     POST /spider/<key>/3/search     body {wd: "<关键词>"}       → {list:[vod_*]}（有的站点没实现 → 404）
//     POST /spider/<key>/3/play       body {flag, id}            → {url, header?, parse?}
//     两段式（无 op）与 GET 一律 404；key 用去掉 nodejs_ 前缀的那个。
//     详细实测记录见 docs/contract-notes.md。
//
//  ⚠️ **`init` 必须调**（2026-10-10 实测，见 docs/contract-notes.md §8）：
//     源为每个站点单独注册了 `POST /spider/<key>/<type>/init`，站点在这一步才去解析自己
//     真正的上游域名（顺序：配置里的 url → 本机 db → 源的远程配置 → 代码里写死的默认域名）。
//     不调 init 就会一直用代码里那份**会过期的默认域名**，于是首页报
//     `timeout of 15000ms exceeded` / `getaddrinfo ENOTFOUND …`（真机与桌面都复现过）。
//     实测：虎斑|4K 不调 init 15 秒超时；调一次 init 后同一个请求 0.4 秒返回内容。
//     所以每个站点在**本次运行时会话里第一次用到之前**先 init 一次（见 initSite）。
//

import Foundation

/// 首页内容：分类 + （可能的）一批条目 + 每个分类的筛选项
struct HomeContent {
    var categories: [Category]
    var items: [VodItem]
    /// key = type_id；值是这一分类的筛选项（源实测确实会返回 filters）
    var filters: [String: [FilterGroup]] = [:]
}

/// 一个筛选维度（例如「地区」「类型」）
struct FilterGroup: Identifiable, Hashable {
    var id: String
    var name: String
    var options: [FilterOption]
}

struct FilterOption: Hashable {
    var name: String
    var value: String
}

final class NodeClient {

    /// 主源的服务地址（多源下是第一个就绪的源；诊断屏/配置中心用）
    let serviceBase: String

    /// **每个源各自的本地服务地址**（sourceId → base）。多源同进程时靠它把请求送到对的那个源
    private(set) var bases: [String: String] = [:]

    private let userAgent = "okhttp/3.15.0"
    private let session: URLSession

    /// 已经 init 过的站点（键 = 服务地址 + 站点 key）。
    /// 用 static：运行时重启会换端口 → 自动全部失效，不需要额外清理；
    /// 放在类里（而不是实例里）是因为 loadSites() 可能重建 client。
    private static var initializedSites = Set<String>()
    private static let initLock = NSLock()

    init(serviceBase: String) {
        self.serviceBase = serviceBase
        self.bases = [:]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    // MARK: - 源地址表（多源）

    func setBase(_ base: String, for sourceId: String) {
        bases[sourceId] = base
    }

    func removeBase(for sourceId: String) {
        bases[sourceId] = nil
    }

    /// 站点 / 源 → 该用哪个本地服务地址
    func base(for sourceId: String) -> String? {
        if let base = bases[sourceId] { return base }
        // 兼容：还没有分发表（老流程/打桩）时退回主地址
        return bases.isEmpty ? serviceBase : nil
    }

    // MARK: - 站点初始化（每个站点第一次用之前必须调一次）

    /// 幂等：同一个运行时会话里每个站点只真的发一次请求。
    /// 失败**不算致命**（有的站点没有 init，或它自己能退回默认域名），
    /// 但会把标记撤掉，这样用户点「重试」时会再试一次。
    func initSite(_ site: SiteInfo) async {
        guard let base = base(for: site.sourceId) else { return }
        let token = base + "|" + site.key
        Self.initLock.lock()
        let done = Self.initializedSites.contains(token)
        if !done { Self.initializedSites.insert(token) }
        Self.initLock.unlock()
        guard !done else { return }

        do {
            let payload = try await request(base: base, "POST", api: site.api, query: [:], body: [:], operation: "init")
            let upstream = payload.str("siteUrl") ?? payload.str("url") ?? "-"
            CatyLog.shared.info("site", "\(site.name) 初始化完成（上游地址 \(upstream)）")
        } catch {
            Self.initLock.lock()
            Self.initializedSites.remove(token)
            Self.initLock.unlock()
            // 404 = 这个站点没有 init 路由（很常见），降级为 debug，不吓人
            CatyLog.shared.debug("site", "\(site.name) init 跳过：\(error.localizedDescription)")
        }
    }

    // MARK: - 站点目录（GET /config）

    func configSites(sourceId: String) async throws -> [SiteInfo] {
        guard let base = base(for: sourceId) else { throw CatyError.runtimeDown }
        let payload = try await request(base: base, "GET", api: "/config", query: [:], body: nil)
        guard let mapped = SiteMapper.map(configJSON: payload, sourceId: sourceId) else {
            throw CatyError.configInvalid
        }
        return mapped.sites
    }

    // MARK: - 首页（分类 + 可能有的一批内容）

    func home(site: SiteInfo) async throws -> HomeContent {
        await initSite(site)
        let payload = try await request(base: try requireBase(site), "POST", api: site.api, query: [:], body: [:], operation: "home")
        let categories = Self.parseCategories(payload)
        let items = Self.parseItems(payload, site: site)
        let filters = Self.parseFilters(payload)
        CatyLog.shared.info("site", "\(site.name) 首页：\(categories.count) 个分类，\(items.count) 条内容" +
            (filters.isEmpty ? "" : "，含筛选项"))
        return HomeContent(categories: categories, items: items, filters: filters)
    }

    // MARK: - 分类内容

    /// extend：筛选项（例如 ["area": "us"]）；源实测会带 filter/extend 一起提交
    func category(site: SiteInfo, tid: String?, page: Int,
                  extend: [String: String] = [:]) async throws -> CategoryPage {
        await initSite(site)
        var body: [String: Any] = ["pg": String(page)]
        if let tid, !tid.isEmpty { body["tid"] = tid }
        if !extend.isEmpty {
            body["filter"] = "1"
            body["extend"] = extend
        }

        let payload = try await request(base: try requireBase(site), "POST", api: site.api, query: [:], body: body, operation: "category")
        let items = Self.parseItems(payload, site: site)
        return CategoryPage(categories: Self.parseCategories(payload),
                            items: items,
                            page: payload.int("page") ?? page,
                            pageCount: max(1, payload.int("pagecount") ?? 1))
    }

    // MARK: - 详情（注意：字段名是单数 id，实测 {ids:...} 会返回空）

    func detail(site: SiteInfo, ids: String) async throws -> VodDetail? {
        await initSite(site)
        let payload = try await request(base: try requireBase(site), "POST", api: site.api, query: [:], body: ["id": ids], operation: "detail")
        guard let raw = payload.dictArray("list").first,
              let item = VodItem(json: raw, siteKey: site.key, sourceId: site.sourceId) else {
            return nil
        }
        let parsed = PlayUrlParser.parse(playFrom: raw.str("vod_play_from"), playUrl: raw.str("vod_play_url"))
        return VodDetail(item: item,
                         content: raw.str("vod_content"),
                         actor: raw.str("vod_actor"),
                         director: raw.str("vod_director"),
                         area: raw.str("vod_area"),
                         playFrom: parsed.sourceNames,
                         episodes: parsed.episodesBySource)
    }

    // MARK: - 搜索

    func search(site: SiteInfo, keyword: String) async throws -> [VodItem] {
        await initSite(site)
        let payload = try await request(base: try requireBase(site), "POST", api: site.api, query: [:], body: ["wd": keyword], operation: "search")
        return Self.parseItems(payload, site: site)
    }

    // MARK: - 播放地址

    /// 字段里的串可能是直链（http/https、/proxy…），也可能是不透明标识（base64 token）→ 问一次 play
    func resolvePlay(episodeURL: String, flag: String, site: SiteInfo) async throws -> (url: URL, headers: [String: String]) {
        await initSite(site)
        let trimmed = PlayUrlParser.normalize(episodeURL).trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()

        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            guard let url = URL(string: trimmed) else { throw CatyError.playbackUnsupported }
            return (url, [:])
        }
        if trimmed.hasPrefix("/") {
            guard let url = URL(string: try requireBase(site) + trimmed) else { throw CatyError.playbackUnsupported }
            return (url, [:])
        }

        CatyLog.shared.info("site", "播放标识不是直链 → POST play（flag=\(flag)，id 前 24 位 \(trimmed.prefix(24))…）")
        let payload = try await request(base: try requireBase(site), "POST", api: site.api, query: [:],
                                        body: ["flag": flag, "id": trimmed], operation: "play")

        let urlText = payload.str("url") ?? ""
        guard !urlText.isEmpty, let url = URL(string: urlText) else {
            // 源自己会给出可读的原因（例如"还没有配置夸克 Cookie，请先去配置中心登录夸克"）
            let reason = payload.str("message") ?? "源没有返回播放地址"
            CatyLog.shared.warn("player", "取播放地址失败：\(reason)")
            throw CatySourceError(message: reason)
        }

        var headers: [String: String] = [:]
        if let headerDict = payload.dict("header") {
            for (key, value) in headerDict {
                if let text = value as? String { headers[key] = text }
            }
        } else if let headerText = payload.str("header"),
                  let data = headerText.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (key, value) in object {
                if let text = value as? String { headers[key] = text }
            }
        }
        return (url, headers)
    }

    // MARK: - 解析辅助

    private static func parseCategories(_ payload: [String: Any]) -> [Category] {
        payload.dictArray("class").compactMap { raw -> Category? in
            guard let id = raw.str("type_id"), let name = raw.str("type_name") else { return nil }
            return Category(id: id, name: name)
        }
    }

    private static func parseItems(_ payload: [String: Any], site: SiteInfo) -> [VodItem] {
        payload.dictArray("list").compactMap { VodItem(json: $0, siteKey: site.key, sourceId: site.sourceId) }
    }

    /// 解析 `filters`：形状是 { "<type_id>": [ {key, name, value:[{n, v}]} ] }
    private static func parseFilters(_ payload: [String: Any]) -> [String: [FilterGroup]] {
        guard let raw = payload["filters"] as? [String: Any] else { return [:] }
        var result: [String: [FilterGroup]] = [:]
        for (tid, value) in raw {
            let groups = (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            var parsed: [FilterGroup] = []
            for group in groups {
                let key = group.str("key") ?? ""
                let name = group.str("name") ?? key
                let options = group.dictArray("value").compactMap { option -> FilterOption? in
                    let optionName = option.str("n") ?? option.str("name") ?? ""
                    let optionValue = option.str("v") ?? option.str("value") ?? ""
                    guard !optionName.isEmpty else { return nil }
                    return FilterOption(name: optionName, value: optionValue)
                }
                guard !key.isEmpty, !options.isEmpty else { continue }
                parsed.append(FilterGroup(id: key, name: name, options: options))
            }
            if !parsed.isEmpty { result[tid] = parsed }
        }
        return result
    }

    // MARK: - 底层请求

    /// 站点必须能查到它所属源的服务地址，否则这个源的运行时不在
    private func requireBase(_ site: SiteInfo) throws -> String {
        guard let base = base(for: site.sourceId) else {
            CatyLog.shared.warn("site", "源 \(site.sourceId) 没有本地服务地址（未启动？）")
            throw CatyError.runtimeDown
        }
        return base
    }

    private func makeURL(base: String, api: String, operation: String?, query: [String: String]) -> URL? {
        var path = api.hasPrefix(NodeRoute.scheme) ? String(api.dropFirst(NodeRoute.scheme.count)) : api
        if !path.hasPrefix("/") { path = "/" + path }
        if let operation, !operation.isEmpty {
            while path.hasSuffix("/") { path.removeLast() }
            path += "/" + operation
        }
        var components = URLComponents(string: base + path)
        if !query.isEmpty {
            components?.queryItems = query
                .filter { !$0.value.isEmpty }
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components?.url
    }

    /// 统一的请求入口：GET 带 query，POST 带 JSON body
    private func request(base: String, _ method: String, api: String, query: [String: String],
                         body: [String: Any]?, operation: String? = nil) async throws -> [String: Any] {
        guard let url = makeURL(base: base, api: api, operation: operation, query: query) else {
            CatyLog.shared.warn("site", "无法拼接 URL：api=\(api) op=\(operation ?? "-")")
            throw CatyError.requestFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let body, method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
            CatyLog.shared.info("site", "\(method) \(url.path)\(url.query.map { "?\($0)" } ?? "") → \(code)  \(data.count)B  \(elapsed)")

            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

            guard (200..<300).contains(code) else {
                // 把源自己给的 message 带出来（排错最省时间，直接显示给用户）
                let message = object?.str("message") ?? String(decoding: data.prefix(160), as: UTF8.self)
                CatyLog.shared.warn("site", "\(url.path) 返回 \(code)：\(message)")
                if code == 404 { throw CatyError.siteEmpty }
                let readable = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !readable.isEmpty, readable != "Not Found" {
                    throw CatySourceError(message: readable)
                }
                throw CatyError.requestFailed
            }
            guard let object else {
                let head = String(decoding: data.prefix(200), as: UTF8.self)
                CatyLog.shared.warn("site", "响应不是 JSON：\(head)")
                throw CatyError.decodeFailed
            }
            return object
        } catch let error as CatyError {
            throw error
        } catch let error as CatySourceError {
            throw error
        } catch {
            CatyLog.shared.warn("site", "\(method) \(url.path) 失败：\(error.localizedDescription)")
            throw CatyError.requestFailed
        }
    }
}
