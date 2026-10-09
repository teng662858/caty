//
//  NodeClient.swift
//  访问本地 Node 服务的客户端
//
//  ⚠️ 契约是 **M0 实测**出来的（tools/host/node-host.mjs --run --probe-routes），不是猜的：
//     GET  /config                    站点目录（唯一一个 GET）
//     POST /spider/<key>/3/home       body {}                    → {class:[{type_id,type_name}], filters}
//     POST /spider/<key>/3/category   body {tid, pg}             → {page, pagecount, list:[vod_*]}
//     POST /spider/<key>/3/detail     body {id: "<vod_id>"}      → {list:[vod_* 含 vod_play_from/url]}
//     POST /spider/<key>/3/search     body {wd: "<关键词>"}       → {list:[vod_*]}（有的站点没实现 → 404）
//     POST /spider/<key>/3/play       body {flag, id}            → {url, header?, parse?}
//     两段式（无 op）与 GET 一律 404；key 用去掉 nodejs_ 前缀的那个。
//     详细实测记录见 docs/contract-notes.md。
//

import Foundation

/// 首页内容：分类 + （可能的）一批条目 + 筛选项
struct HomeContent {
    var categories: [Category]
    var items: [VodItem]
}

final class NodeClient {

    let serviceBase: String

    private let userAgent = "okhttp/3.15.0"
    private let session: URLSession

    init(serviceBase: String) {
        self.serviceBase = serviceBase
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    // MARK: - 站点目录（GET /config）

    func configSites(sourceId: String) async throws -> [SiteInfo] {
        let payload = try await request("GET", api: "/config", query: [:], body: nil)
        guard let mapped = SiteMapper.map(configJSON: payload, sourceId: sourceId) else {
            throw CatyError.configInvalid
        }
        return mapped.sites
    }

    // MARK: - 首页（分类 + 可能有的一批内容）

    func home(site: SiteInfo) async throws -> HomeContent {
        let payload = try await request("POST", api: site.api, query: [:], body: [:], operation: "home")
        let categories = Self.parseCategories(payload)
        let items = Self.parseItems(payload, site: site)
        CatyLog.shared.info("site", "\(site.name) 首页：\(categories.count) 个分类，\(items.count) 条内容")
        return HomeContent(categories: categories, items: items)
    }

    // MARK: - 分类内容

    func category(site: SiteInfo, tid: String?, page: Int) async throws -> CategoryPage {
        var body: [String: Any] = ["pg": String(page)]
        if let tid, !tid.isEmpty { body["tid"] = tid }

        let payload = try await request("POST", api: site.api, query: [:], body: body, operation: "category")
        let items = Self.parseItems(payload, site: site)
        return CategoryPage(categories: Self.parseCategories(payload),
                            items: items,
                            page: payload.int("page") ?? page,
                            pageCount: max(1, payload.int("pagecount") ?? 1))
    }

    // MARK: - 详情（注意：字段名是单数 id，实测 {ids:...} 会返回空）

    func detail(site: SiteInfo, ids: String) async throws -> VodDetail? {
        let payload = try await request("POST", api: site.api, query: [:], body: ["id": ids], operation: "detail")
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
        let payload = try await request("POST", api: site.api, query: [:], body: ["wd": keyword], operation: "search")
        return Self.parseItems(payload, site: site)
    }

    // MARK: - 播放地址

    /// 字段里的串可能是直链（http/https、/proxy…），也可能是不透明标识（base64 token）→ 问一次 play
    func resolvePlay(episodeURL: String, flag: String, site: SiteInfo) async throws -> (url: URL, headers: [String: String]) {
        let trimmed = PlayUrlParser.normalize(episodeURL).trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()

        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            guard let url = URL(string: trimmed) else { throw CatyError.playbackUnsupported }
            return (url, [:])
        }
        if trimmed.hasPrefix("/") {
            guard let url = URL(string: serviceBase + trimmed) else { throw CatyError.playbackUnsupported }
            return (url, [:])
        }

        CatyLog.shared.info("site", "播放标识不是直链 → POST play（flag=\(flag)，id 前 24 位 \(trimmed.prefix(24))…）")
        let payload = try await request("POST", api: site.api, query: [:],
                                        body: ["flag": flag, "id": trimmed], operation: "play")

        let urlText = payload.str("url") ?? ""
        guard !urlText.isEmpty, let url = URL(string: urlText) else {
            // 源自己会给出可读的原因（例如"还没有配置夸克 Cookie，请先去配置中心登录夸克"）
            let reason = payload.str("message") ?? "源没有返回播放地址"
            CatyLog.shared.warn("player", "取播放地址失败：\(reason)")
            throw CatyError.playbackUnsupported
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

    // MARK: - 底层请求

    private func makeURL(api: String, operation: String?, query: [String: String]) -> URL? {
        var path = api.hasPrefix(NodeRoute.scheme) ? String(api.dropFirst(NodeRoute.scheme.count)) : api
        if !path.hasPrefix("/") { path = "/" + path }
        if let operation, !operation.isEmpty {
            while path.hasSuffix("/") { path.removeLast() }
            path += "/" + operation
        }
        var components = URLComponents(string: serviceBase + path)
        if !query.isEmpty {
            components?.queryItems = query
                .filter { !$0.value.isEmpty }
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components?.url
    }

    /// 统一的请求入口：GET 带 query，POST 带 JSON body
    private func request(_ method: String, api: String, query: [String: String],
                         body: [String: Any]?, operation: String? = nil) async throws -> [String: Any] {
        guard let url = makeURL(api: api, operation: operation, query: query) else {
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
                // 把源自己给的 message 带出来（排错最省时间）
                let message = object?.str("message") ?? String(decoding: data.prefix(160), as: UTF8.self)
                CatyLog.shared.warn("site", "\(url.path) 返回 \(code)：\(message)")
                if code == 404 { throw CatyError.siteEmpty }
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
        } catch {
            CatyLog.shared.warn("site", "\(method) \(url.path) 失败：\(error.localizedDescription)")
            throw CatyError.requestFailed
        }
    }
}
