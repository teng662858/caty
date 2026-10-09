//
//  RuntimeCoordinator.swift
//  多源编排（P3 起；2026-10-10 改成**一个 Node 进程跑多个源**）
//
//  ⚠️ 两条约束决定了这里的形状：
//   1. iOS 上 node_start 不可重入：一个进程只能起一次 Node（见 NodeRuntime 文件头）。
//   2. 但 bootstrap.js 支持在同一个进程里**依次 start 多个 bundle**，并开了控制口 /ctl/source。
//  → 所以"已取到包的源全部一起启动"，每个源一个本地端口；首页的源列表就是所有源的站点并集，
//    **切换源是秒切**（用户 2026-10-10 反馈："同类 APP 不用关 App 就能换源"）。
//  → 之后新开启一个源（或者某个源要重试）也走控制口，**同样不需要重启 App**。
//
//  取包失败/契约不支持的源不会挡住其它源（逐个 try，失败的记在记录里）。
//

import Foundation
import Combine

final class RuntimeCoordinator: ObservableObject {

    enum Phase: String {
        case idle, checking, downloading, launching, ready, failed, unsupported

        var label: String {
            switch self {
            case .idle: return "未启动"
            case .checking: return "检查更新中"
            case .downloading: return "下载/校验中"
            case .launching: return "启动中"
            case .ready: return "已就绪"
            case .failed: return "失败"
            case .unsupported: return "契约不支持"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var activeSourceName: String?
    @Published private(set) var activeBundleMD5: String?
    @Published private(set) var lastMessage: String?
    @Published private(set) var records: [SourceRecord] = []
    /// 站点目录 = **所有正在运行的源**的站点并集（每个站点都带自己的 sourceId）
    @Published private(set) var sites: [SiteInfo] = []
    /// 正在运行的源 id（设置页用它显示"运行中"）
    @Published private(set) var runningSourceIds: Set<String> = []
    /// 每个源给用户看的状态文案（sourceId → "运行中 94 站点" / 失败原因）
    @Published private(set) var sourceNotes: [String: String] = [:]

    let runtime = NodeRuntime()
    /// 运行时就绪后才有值；HomeView/BrowseView 用它取数
    private(set) var client: NodeClient?

    private let store = SourceStore.shared
    private let bundles = BundleStore()
    private var started = false
    private var importing = false
    private var cancellables: Set<AnyCancellable> = []
    /// sourceId → 该源的站点目录（切源时不必重新拉）
    private var sitesBySource: [String: [SiteInfo]] = [:]
    private var sourcesById: [String: SourceRecord] = [:]

    init() {
        // 嵌套的 ObservableObject 不会自动把变化传给外层（runtime 的 @Published 不会刷新观察本类的界面），
        // 所以这里手工转发一次，否则首页上的运行状态会是旧值。
        runtime.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// 提示文案：还有哪些改动要重启才生效
    static let restartHint = "取包/新增源的改动要重启 App 才生效（iOS 上一个进程只能启动一次 Node）"

    // MARK: - 启动

    func refreshRecords() {
        records = store.all()
        sourcesById = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    func start() async {
        guard !started else { return }
        started = true
        refreshRecords()

        // 运行时就绪（每有一个源起来就会更新一次）→ 按源拉站点目录
        runtime.$sourceBases
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bases in
                guard let self else { return }
                Task { await self.syncSites(bases: bases) }
            }
            .store(in: &cancellables)

        runtime.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                if state == .ready { self.phase = .ready }
                if state == .failed { self.phase = .failed }
                if state == .exited { self.phase = .failed }
            }
            .store(in: &cancellables)

        let enabled = store.all().filter { $0.enabled }
        guard !enabled.isEmpty else {
            phase = .idle
            lastMessage = "还没有导入源 → 先跑打桩源自检"
            CatyLog.shared.info("site", "未导入任何源，启动打桩 bundle")
            runtime.bootstrapStub()
            return
        }

        // 挨个取包（缓存命中就秒过）；失败/契约不支持的跳过，不挡别的源
        var specs: [SourceSpec] = []
        var seenMD5 = Set<String>()
        for source in enabled {
            guard let spec = await prepare(source, dedupe: &seenMD5) else { continue }
            specs.append(spec)
        }
        refreshRecords()

        guard !specs.isEmpty else {
            phase = .failed
            lastMessage = "已启用的源都取包失败 —— 已回退到打桩源；修好后在「源」页点「重试取包」"
            CatyLog.shared.error("site", "所有已启用的源都取包失败，回退打桩源")
            runtime.bootstrapStub()
            return
        }

        activeSourceName = sourcesById[specs[0].id]?.displayName
        phase = .launching
        lastMessage = "启动 \(specs.count) 个源…"
        CatyLog.shared.info("site", "启动 \(specs.count) 个源：\(specs.map(\.id).joined(separator: ", "))")
        runtime.launch(sources: specs)
    }

    /// 取包（下载/校验/缓存）→ 拿到可启动的 spec；返回 nil 表示这个源这次起不来
    private func prepare(_ source: SourceRecord, dedupe seenMD5: inout Set<String>) async -> SourceSpec? {
        phase = .downloading
        do {
            let result = try await bundles.ensureBundle(for: source)
            var record = source
            record.lastIndexMD5 = result.indexMD5
            record.lastConfigMD5 = result.configMD5
            record.lastContractKind = result.contractKind
            record.lastCheckedAt = Date()
            record.lastError = nil

            guard result.contractKind == BundleStore.contractB else {
                record.lastError = "这是 \(result.contractKind) 型的源，当前版本只支持宿主集成型（contract-b）"
                store.upsert(record)
                sourceNotes[source.id] = "契约不支持"
                CatyLog.shared.error("site", "跳过 \(source.displayName)：\(record.lastError ?? "")")
                return nil
            }

            store.upsert(record)
            activeBundleMD5 = activeBundleMD5 ?? String(result.indexMD5.prefix(12))

            // 同一份 bundle（镜像源）只起一份，别白占内存
            if seenMD5.contains(result.indexMD5) {
                sourceNotes[source.id] = "与另一个源是同一份 bundle → 合并（切换时用同一个实例）"
                CatyLog.shared.info("site", "\(source.displayName) 与已启动的源是同一份 bundle，不再重复启动")
                return nil
            }
            seenMD5.insert(result.indexMD5)

            lastMessage = "\(source.displayName)：\(result.reused ? "缓存命中" : "已下载 \(result.bytes / 1024) KB")"
            sourceNotes[source.id] = result.reused ? "缓存命中，启动中…" : "已下载，启动中…"
            return SourceSpec(id: source.id,
                              index: result.indexFile,
                              config: result.configFile,
                              dataRoot: result.dataRoot)
        } catch {
            var record = source
            record.lastError = error.localizedDescription
            record.lastCheckedAt = Date()
            store.upsert(record)
            sourceNotes[source.id] = error.localizedDescription
            CatyLog.shared.error("site", "\(source.displayName) 取包失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 站点目录（每个源各拉一次，按记录顺序合并）

    @MainActor
    private func syncSites(bases: [String: String]) async {
        guard let primary = runtime.serviceBase else { return }
        if client == nil {
            client = NodeClient(serviceBase: primary)
        }
        guard let client else { return }

        runningSourceIds = Set(bases.keys)
        var merged: [SiteInfo] = []
        // 顺序：先按源清单里的顺序，再补上不在清单里的（例如打桩源 dev-stub）
        let known = records.map(\.id).filter { bases[$0] != nil }
        let extra = bases.keys.filter { id in !records.contains { $0.id == id } }.sorted()
        for id in known + extra {
            guard let base = bases[id] else { continue }
            client.setBase(base, for: id)
            if sitesBySource[id] == nil {
                do {
                    let mapped = try await client.configSites(sourceId: id)
                    sitesBySource[id] = mapped
                    CatyLog.shared.info("site", "\(sourcesById[id]?.displayName ?? id) 站点目录：\(mapped.count) 个")
                } catch {
                    sitesBySource[id] = []
                    CatyLog.shared.warn("site", "\(sourcesById[id]?.displayName ?? id) 站点目录失败：\(error.localizedDescription)")
                }
            }
            let list = sitesBySource[id] ?? []
            sourceNotes[id] = list.isEmpty ? "运行中（站点目录为空）" : "运行中 · \(list.count) 个站点"
            merged.append(contentsOf: list)
        }
        // 已经不在运行的源：清掉它的站点，别让首页点进去报"运行时未运行"
        for id in Array(sitesBySource.keys) where bases[id] == nil {
            sitesBySource[id] = nil
            client.removeBase(for: id)
            if sourcesById[id]?.enabled == true { sourceNotes[id] = "未运行" }
        }
        sites = merged
        if sites.isEmpty {
            lastMessage = "站点目录还没就绪（等源起来）"
        } else {
            lastMessage = "共 \(sites.count) 个站点，来自 \(runningSourceIds.count) 个源"
        }
    }

    // MARK: - 开关 / 重试（运行期即时生效，不用重启 App）

    /// 开关一个源：开 → 取包（缓存命中就秒）→ 走控制口启动它；关 → 停掉它的本地服务
    @MainActor
    func setSourceEnabled(_ id: String, _ enabled: Bool) async {
        guard var record = store.record(id: id) else { return }
        record.enabled = enabled
        store.upsert(record)
        refreshRecords()

        if !enabled {
            if runningSourceIds.contains(id) {
                _ = await runtime.stopSource(id)
                runningSourceIds.remove(id)
                sitesBySource[id] = nil
                client?.removeBase(for: id)
                sites = records.compactMap { sitesBySource[$0.id] }.flatMap { $0 }
                sourceNotes[id] = "已停用（内存要等重启 App 才彻底释放）"
            } else {
                sourceNotes[id] = "已停用"
            }
            CatyLog.shared.info("site", "源 \(id) 已停用")
            return
        }

        // 打开：Node 还没起来过（例如打桩模式）→ 只能重启
        guard runtime.launchCount > 0, runtime.controlBase != nil else {
            sourceNotes[id] = "已开启 → 重启 App 后生效"
            lastMessage = "「\(record.displayName)」已开启，重启 App 后生效"
            return
        }

        var seen = Set<String>()
        guard let spec = await prepare(record, dedupe: &seen) else { return }
        if let address = await runtime.startSource(spec) {
            CatyLog.shared.info("site", "\(record.displayName) 已运行期启动 → \(address)")
            client?.setBase(address, for: id)
            runningSourceIds.insert(id)
            if let client {
                do {
                    let mapped = try await client.configSites(sourceId: id)
                    sitesBySource[id] = mapped
                    sourceNotes[id] = "运行中 · \(mapped.count) 个站点"
                } catch {
                    sitesBySource[id] = []
                    sourceNotes[id] = "启动成功，但站点目录取不到：\(error.localizedDescription)"
                }
            }
            sites = records.compactMap { sitesBySource[$0.id] }.flatMap { $0 }
            lastMessage = "「\(record.displayName)」已启动，可以直接用了"
        } else {
            sourceNotes[id] = runtime.sourceErrors[id] ?? "启动失败（看诊断日志）"
            lastMessage = "「\(record.displayName)」启动失败"
        }
    }

    /// 重试某个源的取包（「源」页的「重试」按钮）——现在成功就能**直接跑起来**，不用重启
    @MainActor
    func retrySource(_ id: String) async {
        guard let record = store.record(id: id) else { return }
        refreshRecords()
        await setSourceEnabled(id, true)
        if sourceNotes[id]?.hasPrefix("运行中") == true {
            phase = .ready
        } else if runtime.launchCount == 0 {
            var updated = record
            updated.lastError = nil
            store.upsert(updated)
            refreshRecords()
            lastMessage = "包已就绪 → 重启 App 后生效"
        }
    }

    // MARK: - 导入 / 删除

    /// 返回 nil 表示成功，否则是给用户看的错误文案
    func importSource(_ raw: String) async -> String? {
        guard !importing else { return "上一个导入还在进行，稍等一下" }
        importing = true
        defer { importing = false }

        let parsed: ParsedSubscription
        do {
            parsed = try SubscriptionParser.parse(raw)
        } catch {
            return "地址不对：需要形如 http(s)://user:pass@host/index.js.md5（原文：\(raw.prefix(48))）"
        }

        if store.record(id: parsed.id) != nil {
            return "这个源已经导入过了（地址去掉口令后完全一样）"
        }

        if let credentials = parsed.credentials {
            KeychainStore.set(credentials, account: parsed.id)
        }

        let host = URL(string: parsed.cleanURL)?.host ?? parsed.cleanURL
        var record = SourceRecord(id: parsed.id,
                                  displayName: host,
                                  url: parsed.cleanURL,
                                  enabled: true,
                                  mirrors: [],
                                  lastIndexMD5: nil,
                                  lastConfigMD5: nil,
                                  lastContractKind: nil,
                                  lastCheckedAt: nil,
                                  lastError: nil,
                                  createdAt: Date())

        phase = .downloading
        CatyLog.shared.info("store", "导入源：\(SubscriptionParser.mask(parsed.cleanURL))")

        do {
            let result = try await bundles.ensureBundle(for: record)
            record.lastIndexMD5 = result.indexMD5
            record.lastConfigMD5 = result.configMD5
            record.lastContractKind = result.contractKind
            record.lastCheckedAt = Date()
            store.upsert(record)

            // 镜像表：bundle 的 MD5 才是身份（docs/00 §8.2 结论 2）
            for other in store.all() where other.id != record.id {
                guard let md5 = other.lastIndexMD5, md5 == result.indexMD5 else { continue }
                var updated = other
                if !updated.mirrors.contains(record.url) { updated.mirrors.append(record.url) }
                store.upsert(updated)
                CatyLog.shared.info("store",
                    "\(record.displayName) 与 \(other.displayName) 是同一份 bundle（MD5 \(String(result.indexMD5.prefix(12)))…）→ 已记为镜像")
            }

            refreshRecords()
            activeBundleMD5 = String(result.indexMD5.prefix(12))
            sourceNotes[record.id] = "已导入 · 点开关即可启动（不用重启）"
            lastMessage = "导入成功：打开它的开关就能用（\(result.reused ? "复用本机已有副本" : "已下载 \(result.bytes / 1024) KB")）"
            return nil
        } catch {
            record.lastError = error.localizedDescription
            record.lastCheckedAt = Date()
            store.upsert(record)
            refreshRecords()
            return error.localizedDescription
        }
    }

    func delete(id: String) {
        if runningSourceIds.contains(id) {
            Task { _ = await runtime.stopSource(id) }
        }
        sitesBySource[id] = nil
        sourceNotes[id] = nil
        store.remove(id: id)
        refreshRecords()
        sites = records.compactMap { sitesBySource[$0.id] }.flatMap { $0 }
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        // 兼容老调用：走同一条即时生效的路径
        Task { await setSourceEnabled(id, enabled) }
    }
}
