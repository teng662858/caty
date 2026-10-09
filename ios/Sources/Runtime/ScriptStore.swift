//
//  ScriptStore.swift
//  「站点脚本」管理（P6+）—— 为什么需要它：
//
//  容器型源（catpaw/douer/smdl/XPTV 这一家）里有一批站点（界面上叫「直」xxx / 「盘」xxx）
//  **没有内建实现**，要靠外部 JS 脚本才跑得起来：脚本按 `<站点key>.js` 命名放进
//  「脚本目录」，bundle 启动时逐个 require 并注册路由；没有脚本时这些站点就是
//  `Dynamic spider handler not found: post /home`（桌面上实测过）。
//
//  脚本目录怎么定的（读 bundle 源码 + 实测）：
//    · catpaw 系：`$NODE_PATH/js`，没有 NODE_PATH 时用
//      `~/Library/Application Support/CatPaw/js`（iOS/macOS 同 darwin 分支；宿主把 HOME 指到 dataRoot）
//    · 另一支系：`$CATPAW_CUSTOM_SPIDER_DIR` / 配置里的 customSpiders.dir / `$NODE_PATH/custom-spiders`
//  所以我们就**往这几个地方都放一份**，谁认哪个都能用上。
//
//  别设 NODE_PATH：那会把源的配置库（ConfigStore 用 NODE_PATH 当数据目录）挪走。
//

import Foundation
import CryptoKit

final class ScriptStore {

    static let shared = ScriptStore()

    struct Script: Identifiable, Hashable {
        let name: String          // 文件名，例如 juzhi.js
        let path: String
        let bytes: Int
        let modified: Date?
        var id: String { "\(name)|\(path)" }
        var siteKey: String { name.replacingOccurrences(of: ".js", with: "") }
    }

    private let fm = FileManager.default
    private let lock = NSLock()

    private init() {}

    // MARK: - 目录

    /// 共享的脚本目录（给需要环境变量的那一支用）
    func sharedDir() throws -> URL {
        let support = try CatyPaths.appSupport()
        return try CatyPaths.subdir(support, "spiders")
    }

    /// 某个源自己的脚本目录（catpaw 系看的就是这个）
    func dirs(for sourceId: String) -> [URL] {
        var result: [URL] = []
        if let dataRoot = try? CatyPaths.dataRoot(sourceId) {
            // catpaw 系：~/Library/Application Support/CatPaw/js（HOME=dataRoot）
            result.append(dataRoot.appendingPathComponent("Library/Application Support/CatPaw/js"))
            // 通用：<dataRoot>/js
            result.append(dataRoot.appendingPathComponent("js"))
            // 另一支：<dataRoot>/custom-spiders
            result.append(dataRoot.appendingPathComponent("custom-spiders"))
        }
        if let shared = try? sharedDir() {
            result.append(shared)
        }
        return result
    }

    // MARK: - 读取

    /// 列出所有装了脚本的目录里的 .js（去重按名字）
    func installed(for sourceId: String) -> [Script] {
        var seen = Set<String>()
        var result: [Script] = []
        for dir in dirs(for: sourceId) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.lowercased().hasSuffix(".js") && !name.hasPrefix(".") {
                guard !seen.contains(name) else { continue }
                seen.insert(name)
                let url = dir.appendingPathComponent(name)
                let attributes = try? fm.attributesOfItem(atPath: url.path)
                result.append(Script(name: name,
                                     path: url.path,
                                     bytes: (attributes?[.size] as? Int) ?? 0,
                                     modified: attributes?[.modificationDate] as? Date))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    // MARK: - 安装

    enum ScriptError: LocalizedError {
        case badURL
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "地址要写成 http(s)://…/xxx.cjs.md5（或 .js.md5 / 直接 .js）"
            case .empty(let name): return "脚本内容为空：\(name)"
            }
        }
    }

    /// 从订阅地址下载一个脚本（`.cjs.md5` / `.js.md5` / 直接 `.js`），写进所有脚本目录。
    /// 带 .md5 后缀时会先取同名 md5 文件校验（和 bundle 下载同一套习惯）。
    @discardableResult
    func install(fromSubscription rawURL: String, sourceId: String) async throws -> [String] {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ScriptError.badURL
        }

        var authHeader: String?
        if let user = components.user {
            authHeader = "Basic " + Data("\(user):\(components.password ?? "")".utf8).base64EncodedString()
            components.user = nil
            components.password = nil
        }
        guard var url = components.url else { throw ScriptError.badURL }

        // 1) 是 .md5 标记 → 先校验，再取真正的脚本
        let isMarker = url.path.lowercased().hasSuffix(".md5")
        var expectedHash: String?
        if isMarker {
            let markerURL = url
            let marker = try await fetchText(markerURL, auth: authHeader, maxBytes: 4096)
            let hash = marker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard hash.count == 32 else { throw ScriptError.badURL }
            expectedHash = hash
            url = url.deletingPathExtension()      // xxx.js.md5 → xxx.js
        }

        let body = try await fetchData(url, auth: authHeader, maxBytes: 8 * 1024 * 1024)
        if let expectedHash {
            let got = Insecure.MD5.hash(data: body).map { String(format: "%02x", $0) }.joined()
            guard got == expectedHash else {
                throw ScriptError.empty("\(url.lastPathComponent)（MD5 不匹配）")
            }
        }
        guard !body.isEmpty else { throw ScriptError.empty(url.lastPathComponent) }

        // 2) 文件名：xxx.cjs → xxx.js（bundle 只认 .js）
        var name = url.lastPathComponent
        if name.lowercased().hasSuffix(".cjs") { name = String(name.dropLast(4)) + ".js" }
        if !name.lowercased().hasSuffix(".js") { name += ".js" }

        // 3) 写进所有脚本目录（不同源家族看不同目录）
        let targets = dirs(for: sourceId)
        for dir in targets {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? body.write(to: dir.appendingPathComponent(name), options: .atomic)
        }
        CatyLog.shared.info("script", "脚本已装入 \(name)（\(body.count)B）→ \(targets.map(\.lastPathComponent).joined(separator: "/"))")
        return targets.map { $0.appendingPathComponent(name).path }
    }

    /// 从本地文件（Files 里选的 .js/.cjs）安装
    @discardableResult
    func install(fromFile fileURL: URL, sourceId: String) throws -> [String] {
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { throw ScriptError.empty(fileURL.lastPathComponent) }
        var name = fileURL.lastPathComponent
        if name.lowercased().hasSuffix(".cjs") { name = String(name.dropLast(4)) + ".js" }
        if !name.lowercased().hasSuffix(".js") { name += ".js" }
        let targets = dirs(for: sourceId)
        for dir in targets {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
        }
        CatyLog.shared.info("script", "本地脚本已装入 \(name)（\(data.count)B）")
        return targets.map { $0.appendingPathComponent(name).path }
    }

    func remove(_ script: Script) {
        try? fm.removeItem(atPath: script.path)
        CatyLog.shared.info("script", "已删除脚本 \(script.name)")
    }

    // MARK: - 网络

    private func fetchText(_ url: URL, auth: String?, maxBytes: Int) async throws -> String {
        let data = try await fetchData(url, auth: auth, maxBytes: maxBytes)
        return String(decoding: data, as: UTF8.self)
    }

    private func fetchData(_ url: URL, auth: String?, maxBytes: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("okhttp/3.15.0", forHTTPHeaderField: "User-Agent")
        if let auth { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code), data.count <= maxBytes else {
            throw ScriptError.empty("HTTP \(code)（\(url.lastPathComponent)）")
        }
        return data
    }
}
