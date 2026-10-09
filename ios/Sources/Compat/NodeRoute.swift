//
//  NodeRoute.swift
//  路由拼接与 `node:` 自定义 scheme（等价 FongMi 的 NodeRoute.java）
//
//  规格来源：docs/00-protocol-spec.md §3.1 / §3.2
//  桌面等价实现：tools/host/node-host.mjs 的 routeOf() 与 nodeRouteAppend()（已跑通）
//

import Foundation

enum NodeRoute {

    static let scheme = "node:"

    // MARK: - 站点 → 路由（等价 NodeConfigMapper.route()）

    /// 站点带 api 字段 → 归一化成 /xxx；否则 key（去掉 nodejs_ 前缀）+ type → /spider/<key>/<type>
    static func route(for site: [String: Any]) -> String? {
        if let raw = site.str("api"), !raw.isEmpty {
            var api = raw
            if let range = api.range(of: "^[a-z][a-z0-9+.-]*://", options: [.regularExpression, .caseInsensitive]) {
                let afterScheme = api[range.upperBound...]
                if let slash = afterScheme.firstIndex(of: "/") {
                    api = String(afterScheme[slash...])
                } else {
                    api = "/"
                }
            }
            return api.hasPrefix("/") ? api : "/" + api
        }

        var key = site.str("key") ?? ""
        if key.hasPrefix("nodejs_") { key = String(key.dropFirst(7)) }
        guard !key.isEmpty else { return nil }
        let type = site.int("type") ?? 3
        return "/spider/\(key)/\(type)"
    }

    // MARK: - 拼接（等价 NodeRoute.append()）

    /// node:/spider/abc/3?x=1 + /detail → node:/spider/abc/3/detail?x=1
    static func append(_ api: String, endpoint: String?) -> String {
        guard api.hasPrefix(scheme) else { return api }
        var value = String(api.dropFirst(scheme.count))

        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        let queryIndex = value.firstIndex(of: "?")
        let suffix = queryIndex.map { String(value[$0...]) } ?? ""
        var path = queryIndex.map { String(value[..<$0]) } ?? value

        if !path.hasPrefix("/") { path = "/" + path }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }

        var child = (endpoint ?? "").trimmingCharacters(in: .whitespaces)
        if !child.isEmpty && !child.hasPrefix("/") { child = "/" + child }
        if path == "/" && !child.isEmpty { path = "" }

        return scheme + path + child + suffix
    }
}
