//
//  RuntimeCoordinator.swift
//  多源编排（P3）：源清单 → 取包（下载/校验/缓存）→ 启动 → 状态上报
//
//  ⚠️ 启动策略（受 iOS 硬约束，docs/00 §6）：**同一时刻只激活一个源**
//   - 有已启用的源 → 取包 → 启动它
//   - 没有源        → 启动打桩 bundle（P2 自检链路照旧可用）
//   - 导入/切换源后需要**重启 App** 才生效（node_start 不可重入）
//  "单 Node 实例承载多个 bundle" 的方案等 M1 真机数据出来再定，不在 P3 硬做。
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
    /// 站点目录（运行时 /config 映射而来，不落库）
    @Published private(set) var sites: [SiteInfo] = []

    let runtime = NodeRuntime()
    /// 运行时就绪后才有值；HomeView/BrowseView 用它取数
    private(set) var client: NodeClient?

    private let store = SourceStore.shared
    private let bundles = BundleStore()
    private var started = false
    private var importing = false
    private var cancellables: Set<AnyCancellable> = []

    init() {
        // 嵌套的 ObservableObject 不会自动把变化传给外层（runtime 的 @Published 不会刷新观察本类的界面），
        // 所以这里手工转发一次，否则首页上的运行状态会是旧值。
        runtime.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// 提示文案：导入/删除源之后必须重启 App 才生效
    static let restartHint = "改动要重启 App 才生效（iOS 上一个进程只能启动一次 Node）"

    // MARK: - 启动

    func refreshRecords() {
        records = store.all()
    }

    func start() async {
        guard !started else { return }
        started = true
        refreshRecords()

        // 运行时就绪（serverStarted）→ 立刻拉站点目录
        runtime.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, state == .ready else { return }
                Task { await self.loadSites() }
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

        // 挨个试已启用的源：列表里只要有**一个**能用就启动它
        // （否则一个坏源排在前面，会把后面能用的源全挡住）
        for source in enabled {
            if await launch(source) { return }
        }
        lastMessage = "已启用的源都取包失败 —— 已回退到打桩源；修好后在「源」页点「重试取包」"
        CatyLog.shared.error("site", "所有已启用的源都取包失败，回退打桩源")
        runtime.bootstrapStub()
    }

    /// 返回 true 表示这个源成功启动
    @discardableResult
    private func launch(_ source: SourceRecord) async -> Bool {
        activeSourceName = source.displayName
        phase = .checking
        lastMessage = nil

        do {
            phase = .downloading
            let result = try await bundles.ensureBundle(for: source)
            activeBundleMD5 = String(result.indexMD5.prefix(12))

            var record = source
            record.lastIndexMD5 = result.indexMD5
            record.lastConfigMD5 = result.configMD5
            record.lastContractKind = result.contractKind
            record.lastCheckedAt = Date()
            record.lastError = nil

            guard result.contractKind == BundleStore.contractB else {
                phase = .unsupported
                lastMessage = "这是 \(result.contractKind) 型的源，当前版本只支持宿主集成型（contract-b）"
                record.lastError = lastMessage
                store.upsert(record)
                refreshRecords()
                CatyLog.shared.error("site", "拒绝启动：\(lastMessage ?? "")")
                return false
            }

            store.upsert(record)
            refreshRecords()

            phase = .launching
            runtime.launch(sourceId: source.id,
                           index: result.indexFile,
                           config: result.configFile,
                           dataRoot: result.dataRoot)
            lastMessage = result.reused
                ? "缓存命中，未重新下载"
                : "已下载并校验通过（\(result.bytes / 1024) KB）"
            CatyLog.shared.info("site", lastMessage ?? "")
            return true
        } catch {
            phase = .failed
            let reason = error.localizedDescription
            var record = source
            record.lastError = reason
            record.lastCheckedAt = Date()
            store.upsert(record)
            refreshRecords()
            CatyLog.shared.error("site", "\(source.displayName) 取包失败：\(reason)")
            lastMessage = "\(source.displayName) 取包失败：\(reason)"
            return false
        }
    }

    /// 重试某个源的取包（「源」页的「重试」按钮）
    @MainActor
    func retrySource(_ id: String) async {
        guard let record = store.record(id: id) else { return }
        refreshRecords()

        if runtime.launchCount == 0 {
            // Node 还没启动过：直接按正常流程走（成功就起它）
            await launch(record)
            return
        }

        // Node 已经起来了（多半是打桩源）：只能验证包能不能取到，并提示重启
        phase = .downloading
        do {
            let result = try await bundles.ensureBundle(for: record)
            var updated = record
            updated.lastIndexMD5 = result.indexMD5
            updated.lastConfigMD5 = result.configMD5
            updated.lastContractKind = result.contractKind
            updated.lastCheckedAt = Date()
            updated.lastError = nil
            store.upsert(updated)
            activeBundleMD5 = String(result.indexMD5.prefix(12))
            phase = .ready
            lastMessage = "包已就绪（bundle \(String(result.indexMD5.prefix(12)))…）→ 重启 App 后生效"
        } catch {
            var updated = record
            updated.lastError = error.localizedDescription
            updated.lastCheckedAt = Date()
            store.upsert(updated)
            phase = .failed
            lastMessage = "重试仍失败：\(error.localizedDescription)"
            CatyLog.shared.warn("site", "重试失败：\(error.localizedDescription)")
        }
        refreshRecords()
    }

    // MARK: - 站点目录

    /// 从本地 Node 服务的 /config 拉站点（P4 起首页靠它）
    @MainActor
    func loadSites() async {
        guard let base = runtime.serviceBase else {
            CatyLog.shared.warn("site", "运行时还没给出服务地址，跳过拉站点目录")
            return
        }
        let client = NodeClient(serviceBase: base)
        self.client = client
        do {
            let mapped = try await client.configSites(sourceId: runtime.activeSourceId)
            sites = mapped
            lastMessage = "站点目录：\(mapped.count) 个站点"
            CatyLog.shared.info("site", "站点目录就绪：\(mapped.map(\.name).joined(separator: "、"))")
        } catch {
            sites = []
            lastMessage = "站点目录失败：\(error.localizedDescription)"
            CatyLog.shared.warn("site", "拉站点目录失败：\(error.localizedDescription)")
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
            lastMessage = "导入成功：站点目录要重启 App 后才会加载（\(result.reused ? "复用本机已有副本" : "已下载 \(result.bytes / 1024) KB")）"
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
        store.remove(id: id)
        refreshRecords()
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard var record = store.record(id: id) else { return }
        record.enabled = enabled
        store.upsert(record)
        refreshRecords()
        CatyLog.shared.info("store", "源 \(id) enabled=\(enabled)（重启 App 后生效）")
    }
}
