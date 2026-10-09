//
//  SiteMapper.swift
//  /config → 站点目录（等价 FongMi 的 NodeConfigMapper.java）
//
//  规格来源：docs/00-protocol-spec.md §3.1
//  桌面等价实现：tools/host/node-host.mjs 的 mapSites()（已在桌面跑通，含"打桩站点"）
//

import Foundation

enum SiteMapper {

    struct Result {
        var video: [String: Any]
        var sites: [SiteInfo]
        /// 源的色板（配置里的 color[0] 之类），P5 上主题色时用
        var color: [String]
    }

    /// 返回 nil 表示响应结构不对（没有 video 对象）
    static func map(configJSON: Any, sourceId: String) -> Result? {
        var root = configJSON as? [String: Any] ?? [:]
        if let data = root.dict("data") { root = data }
        guard let video = root.dict("video") else {
            CatyLog.shared.warn("site", "Node /config 里没有 video 对象，顶层键：\(root.keys.sorted().joined(separator: ","))")
            return nil
        }

        var sites: [SiteInfo] = []
        for raw in video.dictArray("sites") {
            if let enabled = raw.bool("enable"), enabled == false { continue }
            guard let route = NodeRoute.route(for: raw) else { continue }

            let api = NodeRoute.scheme + route
            var key = raw.str("key") ?? route
            if key.hasPrefix("nodejs_") { key = String(key.dropFirst(7)) }
            if key.hasPrefix("/") { key = String(key.dropFirst()) }

            sites.append(SiteInfo(
                key: key,
                name: raw.str("name") ?? key,
                type: 3,
                api: api,
                searchable: raw.bool("searchable") ?? true,
                enabled: true,
                group: raw.str("group"),
                ext: raw.str("ext"),
                sourceId: sourceId
            ))
        }

        let color = root.strArray("color")
        CatyLog.shared.info("site", "站点目录：\(sites.count) 个站点" + (sites.isEmpty ? "（源没返回 site，可能在索引页里）" : ""))
        return Result(video: video, sites: sites, color: color)
    }
}
