//
//  NodeClient.swift
//  访问本地 Node 服务的客户端（等价 FongMi 的 NodeClient + NodeSpider 的取数部分）
//
//  约定（TVBox 的 type-3 接口）：
//    GET <route>?ac=list&t=<分类>&pg=<页>          分类内容
//    GET <route>?ac=detail&ids=<id>                详情（含 vod_play_from / vod_play_url）
//    GET <route>?ac=search&wd=<关键词>             搜索
//    GET <route>?ac=play&flag=<线路>&id=<集标识>   取真实播放地址（{url, header, parse}）
//
//  ⚠️ 真实源到底用哪套 endpoint，M0 抓包（node-host.mjs --probe-routes）会给出确切答案；
//  现在按生态通用约定实现，并把每次请求的路径/状态码打进日志（site 模块），方便对照。
//

import Foundation

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

    // MARK: - 站点目录

    func configSites(sourceId: String) async throws -> [SiteInfo] {
        let payload = try await getJSON(api: "/config", query: [:])
        guard let mapped = SiteMapper.map(configJSON: payload, sourceId: sourceId) else {
            throw CatyError.configInvalid
        }
        return mapped.sites
    }

    // MARK: - 分类 / 列表

    func category(site: SiteInfo, tid: String?, page: Int) async throws -> CategoryPage {
        var query = ["ac": "list", "pg": String(page)]
        if let tid, !tid.isEmpty { query["t"] = tid }

        let payload = try await getJSON(api: site.api, query: query)
        let items = payload.dictArray("list").compactMap {
            VodItem(json: $0, siteKey: site.key, sourceId: site.sourceId)
        }
        let categories = payload.dictArray("class").compactMap { raw -> Category? in
            guard let id = raw.str("type_id"), let name = raw.str("type_name") else { return nil }
            return Category(id: id, name: name)
        }
        return CategoryPage(categories: categories,
                            items: items,
                            page: payload.int("page") ?? page,
                            pageCount: max(1, payload.int("pagecount") ?? 1))
    }

    // MARK: - 详情

    func detail(site: SiteInfo, ids: String) async throws -> VodDetail? {
        let payload = try await getJSON(api: site.api, query: ["ac": "detail", "ids": ids])
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
        let payload = try await getJSON(api: site.api, query: ["ac": "search", "wd": keyword])
        return payload.dictArray("list").compactMap {
            VodItem(json: $0, siteKey: site.key, sourceId: site.sourceId)
        }
    }

    // MARK: - 播放地址

    /// 直接把字段里的串变成能播的 URL；不是直链时按约定问一次 ac=play
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

        CatyLog.shared.info("site", "播放地址不是直链（\(trimmed.prefix(40))…）→ 问一次 ac=play")
        let payload = try await getJSON(api: site.api, query: ["ac": "play", "flag": flag, "id": trimmed])

        let urlText = payload.str("url") ?? ""
        guard !urlText.isEmpty, let url = URL(string: urlText) else { throw CatyError.playbackUnsupported }

        var headers: [String: String] = [:]
        if let headerDict = payload.dict("header") {
            for (key, value) in headerDict where (value as? String) != nil {
                headers[key] = value as? String
            }
        } else if let headerText = payload.str("header"),
                  let data = headerText.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (key, value) in object where (value as? String) != nil {
                headers[key] = value as? String
            }
        }
        return (url, headers)
    }

    // MARK: - 底层请求

    private func makeURL(api: String, query: [String: String]) -> URL? {
        var path = api.hasPrefix(NodeRoute.scheme) ? String(api.dropFirst(NodeRoute.scheme.count)) : api
        if !path.hasPrefix("/") { path = "/" + path }
        var components = URLComponents(string: serviceBase + path)
        if !query.isEmpty {
            components?.queryItems = query
                .filter { !$0.value.isEmpty }
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components?.url
    }

    private func getJSON(api: String, query: [String: String]) async throws -> [String: Any] {
        guard let url = makeURL(api: api, query: query) else {
            CatyLog.shared.warn("site", "无法拼接 URL：api=\(api) query=\(query)")
            throw CatyError.requestFailed
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
            CatyLog.shared.info("site", "GET \(url.path)\(url.query.map { "?\($0)" } ?? "") → \(code)  \(data.count)B  \(elapsed)")

            guard (200..<300).contains(code) else { throw CatyError.requestFailed }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                let head = String(decoding: data.prefix(200), as: UTF8.self)
                CatyLog.shared.warn("site", "响应不是 JSON：\(head)")
                throw CatyError.decodeFailed
            }
            return object
        } catch let error as CatyError {
            throw error
        } catch {
            CatyLog.shared.warn("site", "GET \(url.path) 失败：\(error.localizedDescription)")
            throw CatyError.requestFailed
        }
    }
}
