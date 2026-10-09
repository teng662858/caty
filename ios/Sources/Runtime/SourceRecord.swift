//
//  SourceRecord.swift
//  源的数据模型 + 订阅地址解析 + 源清单（纯 JSON 文件版）
//
//  规格来源：docs/05-data-model.md §1 / §3 / §4
//
//  ⚠️ 与 docs/05 §2 的差异（有意为之，已记进 docs/04）：
//  源清单先用 JSON 文件（sources/registry.json）存储，**GRDB/SQLite 推迟到 P5** ——
//  收藏/历史/搜索历史那时才需要表结构，而 P3 阶段"少一个依赖 = 少一个报错来源"。
//  迁移时把这份 JSON 一次性导入 source / bundle_version 两张表即可。
//

import Foundation
import CryptoKit

// MARK: - 错误码（与 docs/05 §4 完全一致，文案也照抄）

enum CatyError: String, Error, LocalizedError {
    case noSource, downloadFailed, md5Mismatch, unsupportedContract
    case unauthorized                     // 源站 401/403：账号密码不对（实测 catpaw 会返回 401 Authentication required）
    case runtimeLaunchFailed, bridgeTimeout, configMissing, configInvalid
    case siteEmpty, requestTimeout, requestFailed, decodeFailed
    case playbackUnsupported, proxyRequired, offline, runtimeDown

    var errorDescription: String? {
        switch self {
        case .noSource: return "还没有导入源"
        case .downloadFailed: return "下载失败，请检查网络或换镜像"
        case .md5Mismatch: return "校验不通过，已丢弃本次内容"
        case .unauthorized: return "源站拒绝了账号密码（401）：这个源需要商家给你的账号，地址要写成 http://账号:密码@域名/index.js.md5；如果本来就不该用它，左滑删掉即可"
        case .unsupportedContract: return "不支持的源契约（缺少宿主标记）"
        case .runtimeLaunchFailed: return "源启动失败"
        case .bridgeTimeout: return "运行时准备中"
        case .configMissing: return "源没有返回站点目录"
        case .configInvalid: return "源返回的配置无法解析"
        case .siteEmpty: return "这个源暂时没有可用站点"
        case .requestTimeout: return "响应超时"
        case .requestFailed: return "请求失败"
        case .decodeFailed: return "返回了意外数据"
        case .playbackUnsupported: return "这个格式当前内核播不了"
        case .proxyRequired: return "需要中转代理（防盗链）"
        case .offline: return "已离线 · 显示缓存内容"
        case .runtimeDown: return "运行时未运行"
        }
    }
}

// MARK: - 源自己给出的错误原因

/// 真源出错时会带一条**可读的 message**（实测：`timeout of 15000ms exceeded`、
/// `getaddrinfo ENOTFOUND <域名>`、播放时的「还没有配置夸克 Cookie…」）。
/// 这条信息是排错最省时间的东西，必须原样显示给用户，不能吞成"请求失败"。
/// 单独一个类型是因为 CatyError 是 String 枚举（错误码表 docs/05 §4），不该塞自由文本。
struct CatySourceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - 源状态机（docs/05 §3）

enum SourceState: String, Codable {
    case idle, checking, downloading, verifying, launching, ready, updating, failed, unsupported
}

// MARK: - 源记录

struct SourceRecord: Codable, Identifiable, Equatable {
    var id: String              // sha256(去掉 userinfo 的订阅 URL)
    var displayName: String
    var url: String             // 订阅地址，**不含凭据**
    var enabled: Bool
    var mirrors: [String]       // 同一 bundle MD5 的其它镜像地址（不含凭据）
    var lastIndexMD5: String?
    var lastConfigMD5: String?
    var lastContractKind: String?
    var lastCheckedAt: Date?
    var lastError: String?
    var createdAt: Date

    var shortMD5: String { lastIndexMD5.map { String($0.prefix(12)) } ?? "—" }
}

// MARK: - 订阅地址解析

struct SubscriptionLinks {
    let md5: URL
    let index: URL
    let configMd5: URL
    let config: URL
}

struct ParsedSubscription {
    let cleanURL: String        // 去掉 userinfo
    let credentials: String?    // "user:pass"（未解码前的原样串）
    let id: String              // sha256(cleanURL)
    let links: SubscriptionLinks
}

enum SubscriptionParser {

    /// 形如 http(s)://user:pass@host/path/index.js.md5
    static func parse(_ raw: String) throws -> ParsedSubscription {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CatyError.downloadFailed }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw CatyError.downloadFailed
        }
        guard components.path.lowercased().hasSuffix("/index.js.md5") else {
            throw CatyError.downloadFailed
        }

        var credentials: String? = nil
        if let user = components.user {
            credentials = user + ":" + (components.password ?? "")
        }
        components.user = nil
        components.password = nil
        guard let clean = components.url?.absoluteString else { throw CatyError.downloadFailed }

        var base = components
        base.path = (components.path as NSString).deletingLastPathComponent + "/"
        base.query = nil
        base.fragment = nil
        guard let baseURL = base.url else { throw CatyError.downloadFailed }

        let links = SubscriptionLinks(
            md5: baseURL.appendingPathComponent("index.js.md5"),
            index: baseURL.appendingPathComponent("index.js"),
            configMd5: baseURL.appendingPathComponent("index.config.js.md5"),
            config: baseURL.appendingPathComponent("index.config.js")
        )
        return ParsedSubscription(
            cleanURL: clean,
            credentials: credentials,
            id: sha256Hex(clean),
            links: links
        )
    }

    /// Basic 认证头（凭据不入库，只在这一刻用）
    static func basicAuthHeader(credentials: String) -> String {
        "Basic " + Data(credentials.utf8).base64EncodedString()
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 展示用：把任何形如 scheme://user:pass@host 的串抹掉凭据
    static func mask(_ url: String) -> String {
        url.replacingOccurrences(of: "://[^@/]+@", with: "://<user>:***@", options: .regularExpression)
    }
}

// MARK: - 源清单（JSON 文件版，见文件头的说明）

final class SourceStore {

    static let shared = SourceStore()

    private let lock = NSLock()
    private var records: [SourceRecord] = []
    private let fileURL: URL?

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

    private init() {
        var url: URL? = nil
        do {
            let support = try CatyPaths.appSupport()
            let dir = try CatyPaths.subdir(support, "sources")
            url = dir.appendingPathComponent("registry.json")
        } catch {
            CatyLog.shared.error("store", "无法准备源清单目录：\(error.localizedDescription)")
        }
        fileURL = url
        load()
    }

    // MARK: 读写

    func all() -> [SourceRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    /// 当前激活的源：第一个 enabled 的（iOS 一个进程只能跑一个 Node 实例，见 docs/00 §6）
    func activeSource() -> SourceRecord? {
        all().first { $0.enabled }
    }

    func record(id: String) -> SourceRecord? {
        all().first { $0.id == id }
    }

    func upsert(_ record: SourceRecord) {
        lock.lock()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        let snapshot = records
        lock.unlock()
        save(snapshot)
    }

    func remove(id: String) {
        lock.lock()
        records.removeAll { $0.id == id }
        let snapshot = records
        lock.unlock()
        save(snapshot)

        // 删源要连数据目录一起清（docs/05 §7：删除 App 才清空全部；删源清该源）
        do {
            try FileManager.default.removeItem(at: try CatyPaths.sourceRoot(id))
            KeychainStore.delete(account: id)
            CatyLog.shared.info("store", "已删除源 \(id) 及其数据目录")
        } catch {
            CatyLog.shared.warn("store", "删除源数据目录失败：\(error.localizedDescription)")
        }
    }

    // MARK: 落盘

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        do {
            records = try Self.decoder.decode([SourceRecord].self, from: data)
            CatyLog.shared.info("store", "源清单已加载：\(records.count) 个源")
        } catch {
            CatyLog.shared.error("store", "源清单解析失败（已忽略）：\(error.localizedDescription)")
            records = []
        }
    }

    private func save(_ snapshot: [SourceRecord]) {
        guard let fileURL else { return }
        do {
            let data = try Self.encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            CatyLog.shared.error("store", "源清单写入失败：\(error.localizedDescription)")
        }
    }
}
