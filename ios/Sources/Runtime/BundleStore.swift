//
//  BundleStore.swift
//  bundle 的下载 / 校验 / 缓存 / 原子提交（等价 FongMi NodeBundle + NodeService 的取包部分）
//
//  规格来源：docs/00-protocol-spec.md §1（四件套）、§5（缓存与完整性）、§2.4（契约判别）
//
//  三条硬规则（照抄文档，别改）：
//  1. 不信任 Content-Type（源把 JS 伪装成 image/jpeg）；
//  2. 手动跟随跳转，**拒绝 HTTPS→HTTP 降级**；
//  3. 流式限量（index 32 MB / config 2 MB / md5 1 KB），**不要先下载再判断**。
//
//  源的身份 = bundle 的 MD5（不是 URL）：本机已有同 MD5 的副本时直接复制，
//  换镜像/加同款源都不必再下那 6–9 MB。
//

import Foundation
import CryptoKit

// MARK: - 结果与元数据

struct BundleMeta: Codable {
    var indexMD5: String
    var configMD5: String?
    var bytes: Int
    var contractKind: String
    var fetchedAt: Date
}

struct EnsureResult {
    let sourceId: String
    let indexFile: URL
    let configFile: URL
    let dataRoot: URL
    let indexMD5: String
    let configMD5: String?
    let bytes: Int
    let reused: Bool
    let contractKind: String
}

// MARK: - BundleStore

final class BundleStore {

    static let maxMD5Bytes = 1024
    static let maxConfigBytes = 2 * 1024 * 1024
    static let maxIndexBytes = 32 * 1024 * 1024

    static let contractB = "contract-b-host-integrated"
    static let contractA = "contract-a-service"
    static let contractUnsupported = "unsupported-partial"

    private let userAgent = "okhttp/3.15.0"
    private let timeout: TimeInterval = 30

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - 主流程

    /// 确保这个源的 bundle 可用：能复用就复用，否则下载 → 校验 → 原子提交
    func ensureBundle(for source: SourceRecord) async throws -> EnsureResult {
        let parsed = try SubscriptionParser.parse(source.url)
        let storedCredentials = KeychainStore.get(account: source.id)
        let authorization = storedCredentials.map { SubscriptionParser.basicAuthHeader(credentials: $0) }
        CatyLog.shared.info("store",
            "检查更新：\(SubscriptionParser.mask(source.url))  凭据=\(authorization == nil ? "无" : "有（\(storedCredentials?.count ?? 0) 字符）")")

        let root = try CatyPaths.bundlesRoot(source.id)
        let active = root.appendingPathComponent("active", isDirectory: true)
        let dataRoot = try CatyPaths.dataRoot(source.id)

        // ---- 1) 远端 MD5（这两个文件极小）
        let indexMD5 = try await remoteMD5(parsed.links.md5, authorization: authorization)
        let configMD5 = try? await remoteMD5(parsed.links.configMd5, authorization: authorization)
        CatyLog.shared.info("store",
            "远程 index.js.md5=\(indexMD5)\(configMD5.map { "  index.config.js.md5=\($0)" } ?? "")")

        // ---- 2) 缓存命中？（源站流量与启动速度的关键）
        if let meta = readMeta(active),
           meta.indexMD5 == indexMD5,
           meta.configMD5 == configMD5,
           let data = try? Data(contentsOf: active.appendingPathComponent("index.js")),
           Self.md5Hex(data) == indexMD5 {
            CatyLog.shared.info("store", "缓存命中（MD5 一致），不重新下载；\(data.count)B  \(active.path)")
            cleanupLeftovers(root: root, keep: active)
            return EnsureResult(sourceId: source.id,
                                indexFile: active.appendingPathComponent("index.js"),
                                configFile: active.appendingPathComponent("index.config.js"),
                                dataRoot: dataRoot,
                                indexMD5: indexMD5,
                                configMD5: configMD5,
                                bytes: data.count,
                                reused: true,
                                contractKind: meta.contractKind)
        }

        // ---- 3) 镜像复用：本机已有同一份 bundle（MD5 相同）→ 直接复制
        var reusedFromMirror: URL? = nil
        if let local = localCopy(indexMD5: indexMD5, excluding: source.id) {
            reusedFromMirror = local
            CatyLog.shared.info("store", "本机已有同 MD5 的 bundle → 直接复用，不重新下载：\(local.path)")
        }

        // ---- 4) 下载到 staging，逐个校验
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("\(indexMD5):\(configMD5 ?? "")\n".utf8)
            .write(to: staging.appendingPathComponent(".pending"))

        do {
            // index.js
            let indexData: Data
            if let local = reusedFromMirror {
                indexData = try Data(contentsOf: local)
            } else {
                indexData = try await fetch(parsed.links.index, limit: Self.maxIndexBytes, authorization: authorization).data
            }
            let gotIndexMD5 = Self.md5Hex(indexData)
            guard gotIndexMD5 == indexMD5 else {
                CatyLog.shared.error("store", "index.js MD5 不匹配（期望 \(indexMD5)，实得 \(gotIndexMD5)），已丢弃")
                throw CatyError.md5Mismatch
            }
            CatyLog.shared.info("store", "index.js \(indexData.count)B  MD5 校验通过")

            // 契约判别（在提交之前做：不支持的包不进缓存）
            let contract = Self.detectContract(in: indexData)
            CatyLog.shared.info("store", "契约判别：\(contract)")
            guard contract != Self.contractUnsupported else { throw CatyError.unsupportedContract }

            try indexData.write(to: staging.appendingPathComponent("index.js"), options: .atomic)
            try Data((indexMD5 + "\n").utf8).write(to: staging.appendingPathComponent("index.js.md5"))

            // index.config.js（可选，但真源都有）
            if let configMD5 {
                var configData: Data? = nil
                if let local = reusedFromMirror {
                    let candidate = local.deletingLastPathComponent().appendingPathComponent("index.config.js")
                    if let data = try? Data(contentsOf: candidate), Self.md5Hex(data) == configMD5 {
                        configData = data
                    }
                }
                if configData == nil {
                    configData = try await fetch(parsed.links.config, limit: Self.maxConfigBytes, authorization: authorization).data
                }
                guard let configData, Self.md5Hex(configData) == configMD5 else { throw CatyError.md5Mismatch }
                try configData.write(to: staging.appendingPathComponent("index.config.js"), options: .atomic)
                try Data((configMD5 + "\n").utf8).write(to: staging.appendingPathComponent("index.config.js.md5"))
                CatyLog.shared.info("store", "index.config.js \(configData.count)B  MD5 校验通过")
            } else {
                CatyLog.shared.warn("store", "拿不到 index.config.js.md5，按可选处理（bundle 仍可启动）")
            }

            let meta = BundleMeta(indexMD5: indexMD5, configMD5: configMD5,
                                  bytes: indexData.count, contractKind: contract, fetchedAt: Date())
            try Self.encoder.encode(meta).write(to: staging.appendingPathComponent("meta.json"), options: .atomic)
            try? FileManager.default.removeItem(at: staging.appendingPathComponent(".pending"))

            // ---- 5) 原子提交
            let old = root.appendingPathComponent("active.old-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
            if FileManager.default.fileExists(atPath: active.path) {
                try? FileManager.default.removeItem(at: old)
                try FileManager.default.moveItem(at: active, to: old)
            }
            try FileManager.default.moveItem(at: staging, to: active)
            cleanupLeftovers(root: root, keep: active)
            CatyLog.shared.info("store", "已提交新版本：\(active.path)")

            return EnsureResult(sourceId: source.id,
                                indexFile: active.appendingPathComponent("index.js"),
                                configFile: active.appendingPathComponent("index.config.js"),
                                dataRoot: dataRoot,
                                indexMD5: indexMD5,
                                configMD5: configMD5,
                                bytes: indexData.count,
                                reused: false,
                                contractKind: contract)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    // MARK: - 分步

    private func remoteMD5(_ url: URL, authorization: String?) async throws -> String {
        let response = try await fetch(url, limit: Self.maxMD5Bytes, authorization: authorization)
        let head = String(decoding: response.data.prefix(200), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard (200..<300).contains(response.status) else {
            // 把状态码与响应开头记下来：401=凭据没带上；403/503 且正文有 cf/challenge=被 Cloudflare 拦
            CatyLog.shared.warn("store", "\(url.lastPathComponent) HTTP \(response.status)  正文前 200 字：\(head)")
            throw CatyError.downloadFailed
        }
        let text = String(decoding: response.data, as: UTF8.self)
        guard let md5 = Self.firstMD5(in: text) else {
            CatyLog.shared.warn("store", "\(url.lastPathComponent) 里没有 32 位 MD5；正文前 200 字：\(head)")
            throw CatyError.downloadFailed
        }
        return md5
    }

    private func fetch(_ url: URL, limit: Int, authorization: String?) async throws -> LimitedDownloader.Response {
        try await LimitedDownloader.fetch(url,
                                         limit: limit,
                                         authorization: authorization,
                                         userAgent: userAgent,
                                         timeout: timeout)
    }

    private func readMeta(_ active: URL) -> BundleMeta? {
        let url = active.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(BundleMeta.self, from: data)
    }

    /// 找本机（别的源/别的镜像）已有的同 MD5 bundle
    private func localCopy(indexMD5: String, excluding sourceId: String) -> URL? {
        let fileManager = FileManager.default
        guard let sourcesDir = try? CatyPaths.appSupport().appendingPathComponent("sources", isDirectory: true),
              let dirs = try? fileManager.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil)
        else { return nil }

        for dir in dirs where dir.lastPathComponent != CatyPaths.safe(sourceId) {
            let active = dir.appendingPathComponent("bundles/active", isDirectory: true)
            guard let meta = readMeta(active), meta.indexMD5 == indexMD5 else { continue }
            let index = active.appendingPathComponent("index.js")
            guard let data = try? Data(contentsOf: index), Self.md5Hex(data) == indexMD5 else { continue }
            return index
        }
        return nil
    }

    private func cleanupLeftovers(root: URL, keep: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent != keep.lastPathComponent {
            try? fileManager.removeItem(at: entry)
        }
    }

    // MARK: - 纯函数

    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func firstMD5(in text: String) -> String? {
        guard let range = text.range(of: "[a-fA-F0-9]{32}", options: .regularExpression) else { return nil }
        return String(text[range]).lowercased()
    }

    /// docs/00 §2.4：三个标记齐全 = contract-b；全无 = contract-a；部分出现 = 拒绝加载
    static func detectContract(in data: Data) -> String {
        let hasFactory = data.range(of: Data("catServerFactory".utf8)) != nil
        let hasPort = data.range(of: Data("catDartServerPort".utf8)) != nil
        let hasDev = data.range(of: Data("DEV_HTTP_PORT".utf8)) != nil
        if hasFactory && hasPort && hasDev { return contractB }
        if !hasFactory && !hasPort && !hasDev { return contractA }
        return contractUnsupported
    }
}

// MARK: - 限量下载器（流式，不先下再判断）

final class LimitedDownloader: NSObject, URLSessionDataDelegate {

    struct Response {
        let data: Data
        let status: Int
        let finalURL: URL
    }

    private var continuation: CheckedContinuation<Response, Error>?
    private var session: URLSession?
    private var buffer = Data()
    private var statusCode = -1
    private var redirects = 0
    private var finished = false

    private let limit: Int
    private let userAgent: String
    private let authorization: String?
    private let timeout: TimeInterval

    private init(limit: Int, authorization: String?, userAgent: String, timeout: TimeInterval) {
        self.limit = limit
        self.authorization = authorization
        self.userAgent = userAgent
        self.timeout = timeout
        super.init()
    }

    static func fetch(_ url: URL, limit: Int, authorization: String?,
                      userAgent: String, timeout: TimeInterval) async throws -> Response {
        let downloader = LimitedDownloader(limit: limit, authorization: authorization,
                                         userAgent: userAgent, timeout: timeout)
        return try await downloader.run(url)
    }

    private func run(_ url: URL) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout * 2
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            if let authorization {
                request.setValue(authorization, forHTTPHeaderField: "Authorization")
            }
            session.dataTask(with: request).resume()
        }
    }

    private func finish(_ result: Result<Response, Error>) {
        guard !finished else { return }
        finished = true
        session?.invalidateAndCancel()   // 释放 URLSession 对 delegate(self) 的强引用
        continuation?.resume(with: result)
        continuation = nil
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse { statusCode = http.statusCode }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        if buffer.count > limit {
            CatyLog.shared.warn("store", "响应超过上限 \(limit)B，已中断")
            dataTask.cancel()
            finish(.failure(CatyError.downloadFailed))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard redirects < 5 else {
            CatyLog.shared.warn("store", "跳转次数过多（>5），已中断")
            completionHandler(nil)
            finish(.failure(CatyError.downloadFailed))
            return
        }
        // HTTPS → HTTP 降级直接拒绝（防降级攻击）
        if task.originalRequest?.url?.scheme?.lowercased() == "https",
           request.url?.scheme?.lowercased() == "http" {
            CatyLog.shared.warn("store", "拒绝 HTTPS→HTTP 降级跳转：\(SubscriptionParser.mask(request.url?.absoluteString ?? ""))")
            completionHandler(nil)
            finish(.failure(CatyError.downloadFailed))
            return
        }
        redirects += 1
        var next = request
        // 跨主机跳转不带凭据（例如源站 302 到 OSS：那串直链自带签名，不需要我们的 Authorization）
        if task.originalRequest?.url?.host != request.url?.host {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        CatyLog.shared.debug("store", "跳转 → \(SubscriptionParser.mask(request.url?.absoluteString ?? ""))")
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else {
            let finalURL = task.currentRequest?.url ?? task.originalRequest?.url ?? URL(string: "about:blank")!
            finish(.success(Response(data: buffer, status: statusCode, finalURL: finalURL)))
        }
    }
}
