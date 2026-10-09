//
//  LibraryStore.swift
//  本地库：收藏 / 历史（含断点续播）/ 设置
//
//  实现说明（与 docs/05 的差异，见 docs/04 第 5 轮 ADR 10）：
//  文档原本写 GRDB/SQLite，实际改成**JSON 文件**（和源清单一致）——
//  收藏/历史/设置的数据量都很小（几百条），JSON 足够，
//  且"少一个 SPM 依赖 = 少一个编译/下载失败模式"。将来数据量真大了再迁 GRDB 也不难。
//

import Foundation
import Combine

// MARK: - 可持久化的条目镜像（VodItem 是解析用的，不做 Codable）

struct StoredItem: Codable, Hashable {
    var id: String
    var name: String
    var pic: String?
    var remarks: String?
    var tag: String?
    var typeName: String?
    var year: String?
    var siteKey: String
    var sourceId: String

    init(_ item: VodItem) {
        id = item.id
        name = item.name
        pic = item.pic
        remarks = item.remarks
        tag = item.tag
        typeName = item.typeName
        year = item.year
        siteKey = item.siteKey
        sourceId = item.sourceId
    }

    var asVodItem: VodItem {
        VodItem(id: id, name: name, pic: pic, remarks: remarks, tag: tag,
                typeName: typeName, year: year, siteKey: siteKey, sourceId: sourceId)
    }
}

struct FavoriteRecord: Codable, Identifiable, Hashable {
    var id: String          // "\(sourceId)|\(siteKey)|\(vodId)"
    var item: StoredItem
    var addedAt: Date
}

struct HistoryRecord: Codable, Identifiable, Hashable {
    var id: String
    var item: StoredItem
    var episodeIndex: Int
    var episodeName: String
    var positionSec: Double
    var durationSec: Double
    var updatedAt: Date

    /// 观看进度 0–1
    var progress: Double {
        guard durationSec > 1 else { return 0 }
        return min(1, max(0, positionSec / durationSec))
    }
}

// MARK: - 设置（docs/05 §6 的子集，只做已经能生效的项）

struct AppSettings: Codable {
    var rate: Double = 1.0              // 默认倍速
    var rememberProgress: Bool = true   // 记忆进度（断点续播）
    var gridColumns: Int = 3            // 海报墙每行几个
    var defaultSiteKey: String?         // 首页默认站点
    var historyDays: Int = 60           // 历史保留天数
    /// 播放内核：auto（自动）/ system（系统 AVPlayer）/ mpv（libmpv）。P6 加的
    var playerKernel: String = PlayerKernelPreference.auto.rawValue
    /// 弹幕开关（源支持弹幕时才有效）
    var danmakuEnabled: Bool = false
    /// 弹幕服务来源：local = 源自带的服务；remote = 用户填的远程地址
    var danmakuSource: String = "local"
    var danmakuRemoteURL: String = ""
    var danmakuFontSize: Double = 17
    var danmakuLaneSpacing: Double = 1.6
    var danmakuOpacity: Double = 1.0
    var danmakuShowTop: Bool = true
    var danmakuShowBottom: Bool = true
    /// 屏蔽词（逗号/空格分隔）
    var danmakuBlockWords: String = ""
    /// "跳过片头"的秒数（0 = 不显示这个按钮）
    var skipIntroSeconds: Int = 90

    init() {}

    /// 手写解码：**新增设置项时，老版本存下来的 json 缺这些键也不能让整个库解析失败**
    /// （LibraryStore.load 用的是 try? decode：一旦抛错就"当作没有本地库"，收藏/历史会一起丢）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rate = try container.decodeIfPresent(Double.self, forKey: .rate) ?? 1.0
        rememberProgress = try container.decodeIfPresent(Bool.self, forKey: .rememberProgress) ?? true
        gridColumns = try container.decodeIfPresent(Int.self, forKey: .gridColumns) ?? 3
        defaultSiteKey = try container.decodeIfPresent(String.self, forKey: .defaultSiteKey)
        historyDays = try container.decodeIfPresent(Int.self, forKey: .historyDays) ?? 60
        playerKernel = try container.decodeIfPresent(String.self, forKey: .playerKernel)
            ?? PlayerKernelPreference.auto.rawValue
        danmakuEnabled = try container.decodeIfPresent(Bool.self, forKey: .danmakuEnabled) ?? false
        danmakuSource = try container.decodeIfPresent(String.self, forKey: .danmakuSource) ?? "local"
        danmakuRemoteURL = try container.decodeIfPresent(String.self, forKey: .danmakuRemoteURL) ?? ""
        danmakuFontSize = try container.decodeIfPresent(Double.self, forKey: .danmakuFontSize) ?? 17
        danmakuLaneSpacing = try container.decodeIfPresent(Double.self, forKey: .danmakuLaneSpacing) ?? 1.6
        danmakuOpacity = try container.decodeIfPresent(Double.self, forKey: .danmakuOpacity) ?? 1.0
        danmakuShowTop = try container.decodeIfPresent(Bool.self, forKey: .danmakuShowTop) ?? true
        danmakuShowBottom = try container.decodeIfPresent(Bool.self, forKey: .danmakuShowBottom) ?? true
        danmakuBlockWords = try container.decodeIfPresent(String.self, forKey: .danmakuBlockWords) ?? ""
        skipIntroSeconds = try container.decodeIfPresent(Int.self, forKey: .skipIntroSeconds) ?? 90
    }
}

// MARK: - 库

final class LibraryStore: ObservableObject {

    static let shared = LibraryStore()

    @Published private(set) var favorites: [FavoriteRecord] = []
    @Published private(set) var history: [HistoryRecord] = []
    @Published var settings = AppSettings() {
        didSet { saveSettings() }
    }

    private struct Payload: Codable {
        var favorites: [FavoriteRecord]
        var history: [HistoryRecord]
        var settings: AppSettings
    }

    private let lock = NSLock()
    private let fileURL: URL?
    private let ioQueue = DispatchQueue(label: "caty.library.io", qos: .utility)
    private var lastProgressWrite = Date.distantPast

    private init() {
        fileURL = (try? CatyPaths.appSupport())?.appendingPathComponent("library.json")
        load()
    }

    // MARK: 收藏

    func isFavorite(_ item: VodItem) -> Bool {
        let key = Self.key(for: item)
        lock.lock()
        defer { lock.unlock() }
        return favorites.contains { $0.id == key }
    }

    func toggleFavorite(_ item: VodItem) {
        let key = Self.key(for: item)
        lock.lock()
        if let index = favorites.firstIndex(where: { $0.id == key }) {
            favorites.remove(at: index)
            CatyLog.shared.info("store", "取消收藏：\(item.name)")
        } else {
            favorites.insert(FavoriteRecord(id: key, item: StoredItem(item), addedAt: Date()), at: 0)
            CatyLog.shared.info("store", "已收藏：\(item.name)")
        }
        let snapshot = favorites
        lock.unlock()
        publish(favorites: snapshot)
        saveAsync()
    }

    func removeFavorite(id: String) {
        lock.lock()
        favorites.removeAll { $0.id == id }
        let snapshot = favorites
        lock.unlock()
        publish(favorites: snapshot)
        saveAsync()
    }

    // MARK: 历史 / 断点续播

    func history(for item: VodItem) -> HistoryRecord? {
        let key = Self.key(for: item)
        lock.lock()
        defer { lock.unlock() }
        return history.first { $0.id == key }
    }

    /// 播放中/退出时调用；内部做了写盘节流（最多 5 秒一次），避免频繁 IO
    func updateHistory(item: VodItem,
                       episodeIndex: Int,
                       episodeName: String,
                       position: Double,
                       duration: Double,
                       forceWrite: Bool = false) {
        let key = Self.key(for: item)
        lock.lock()
        let record = HistoryRecord(id: key,
                                   item: StoredItem(item),
                                   episodeIndex: episodeIndex,
                                   episodeName: episodeName,
                                   positionSec: position,
                                   durationSec: duration,
                                   updatedAt: Date())
        if let index = history.firstIndex(where: { $0.id == key }) {
            history[index] = record
        } else {
            history.insert(record, at: 0)
        }
        history.sort { $0.updatedAt > $1.updatedAt }
        // 超过保留期或数量过多的清掉
        let cutoff = Date().addingTimeInterval(-Double(settings.historyDays) * 86400)
        history.removeAll { $0.updatedAt < cutoff }
        if history.count > 500 { history.removeLast(history.count - 500) }
        let snapshot = history
        lock.unlock()

        publish(history: snapshot)

        let now = Date()
        if forceWrite || now.timeIntervalSince(lastProgressWrite) > 5 {
            lastProgressWrite = now
            saveAsync()
        }
    }

    func removeHistory(id: String) {
        lock.lock()
        history.removeAll { $0.id == id }
        let snapshot = history
        lock.unlock()
        publish(history: snapshot)
        saveAsync()
    }

    func clearHistory() {
        lock.lock()
        history = []
        lock.unlock()
        publish(history: [])
        saveAsync()
    }

    func clearFavorites() {
        lock.lock()
        favorites = []
        lock.unlock()
        publish(favorites: [])
        saveAsync()
    }

    // MARK: 工具

    static func key(for item: VodItem) -> String {
        item.sourceId + "|" + item.siteKey + "|" + item.id
    }

    var cacheDescription: String {
        let urlCache = URLCache.shared
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(urlCache.currentDiskUsage))
    }

    func clearImageCache() {
        URLCache.shared.removeAllCachedResponses()
        CatyLog.shared.info("store", "已清空图片缓存")
    }

    // MARK: 落盘

    private func publish(favorites newFavorites: [FavoriteRecord]? = nil,
                         history newHistory: [HistoryRecord]? = nil) {
        // @Published 必须在主线程更新
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let newFavorites { self.favorites = newFavorites }
            if let newHistory { self.history = newHistory }
        }
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else {
            CatyLog.shared.warn("store", "本地库解析失败（已忽略）")
            return
        }
        favorites = payload.favorites
        history = payload.history
        settings = payload.settings
        CatyLog.shared.info("store", "本地库已加载：收藏 \(favorites.count) 条，历史 \(history.count) 条")
    }

    private func saveAsync() {
        lock.lock()
        let payload = Payload(favorites: favorites, history: history, settings: settings)
        lock.unlock()
        guard let fileURL else { return }
        ioQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(payload) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func saveSettings() {
        saveAsync()
    }
}
