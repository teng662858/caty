//
//  AggregatorService.swift
//  多源并发搜索：跨站点同时搜同一个关键词
//
//  设计要点（实测得出的约束）：
//  - 站点数量很大（这套源实测 94 个），一个一个搜太慢 → 分批并发（默认每批 6 个）
//  - **某个站点超时/失败绝不能影响其它站点**（有的站点没实现 search → 整条路由 404）
//  - 结果按「站点 → 条目」分组返回，界面直接按站点分节显示
//

import Foundation

final class AggregatorService {

    struct Hit: Hashable {
        let site: SiteInfo
        let item: VodItem
    }

    /// 只搜声明了 searchable 的站点
    static func searchableSites(_ sites: [SiteInfo]) -> [SiteInfo] {
        sites.filter { $0.searchable }
    }

    /// 并发搜索；onProgress 会在每批完成后回调（用于界面显示"已搜索 x/y 个站点"）
    static func search(keyword: String,
                       sites: [SiteInfo],
                       client: NodeClient?,
                       batchSize: Int = 6,
                       onProgress: (@MainActor (Int, Int) -> Void)? = nil) async -> [Hit] {
        guard let client else { return [] }
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let targets = searchableSites(sites)
        guard !targets.isEmpty else { return [] }

        var collected: [Hit] = []
        var done = 0
        var index = 0

        CatyLog.shared.info("site", "开始跨源搜索「\(trimmed)」：共 \(targets.count) 个站点可搜，每批 \(batchSize) 个")

        while index < targets.count {
            let end = min(index + batchSize, targets.count)
            let batch = Array(targets[index..<end])
            index = end

            await withTaskGroup(of: [Hit].self) { group in
                for site in batch {
                    group.addTask {
                        do {
                            let items = try await client.search(site: site, keyword: trimmed)
                            return items.map { Hit(site: site, item: $0) }
                        } catch {
                            // 单站失败（404=没实现搜索 / 超时 / 解析失败）都不算错，跳过就好
                            CatyLog.shared.debug("site", "\(site.name) 搜索跳过：\(error.localizedDescription)")
                            return []
                        }
                    }
                }
                for await hits in group {
                    collected.append(contentsOf: hits)
                }
            }

            done += batch.count
            await onProgress?(done, targets.count)
        }

        CatyLog.shared.info("site", "搜索完成：「\(trimmed)」命中 \(collected.count) 条，来自 \(Set(collected.map(\.site.key)).count) 个站点")
        return collected
    }
}

// MARK: - 搜索历史（一小份 JSON，放 Application Support）

final class SearchHistoryStore {

    static let shared = SearchHistoryStore()

    private let limit = 30
    private let fileURL: URL?
    private var lock = NSLock()
    private var keywords: [String] = []

    private init() {
        fileURL = (try? CatyPaths.appSupport())?.appendingPathComponent("search-history.json")
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            keywords = list
        }
    }

    func all() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return keywords
    }

    func add(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        keywords.removeAll { $0 == trimmed }
        keywords.insert(trimmed, at: 0)
        if keywords.count > limit { keywords.removeLast(keywords.count - limit) }
        let snapshot = keywords
        lock.unlock()

        if let fileURL, let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func removeAll() {
        lock.lock()
        keywords = []
        lock.unlock()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }
}
