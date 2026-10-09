//
//  NodeRuntime.swift
//  Node 生命周期（P2：先跑内置打桩源，不碰真源）
//
//  关键硬约束（来自 nodejs-mobile 的实测文档，见 docs/07）：
//  1. 一个进程只能跑一个 Node 实例：node_start 会阻塞直到 Node 退出，
//     且**不可重入** —— 要重来只能重启 App。所以 canRelaunch = false。
//  2. 必须在**独立线程**里调 node_start（它会一直占住那个线程）。
//  3. 环境变量必须在 node_start **之前**设好（NODE_COMPILE_CACHE 只读一次）。
//  4. 编译缓存路径含容器 UUID：必须同时开 NODE_COMPILE_CACHE_PORTABLE=1，
//     否则每次重装都会静默全部 miss。
//

import Foundation
import Combine

// MARK: - 线程安全的盒子

/// bridge 在自己的队列上读 /health，主线程写 —— 用它避免跨线程访问 @Published
final class Locked<Value> {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

// MARK: - argv 转换

/// 把 Swift 字符串数组转成 C 的 argv（结尾补 NULL），在 body 调用期间有效
func withCArguments<T>(_ arguments: [String],
                       _ body: (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
    var pointers: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
    pointers.append(nil)
    defer {
        for pointer in pointers {
            if let pointer { free(pointer) }
        }
    }
    return pointers.withUnsafeMutableBufferPointer { buffer in
        body(Int32(arguments.count), buffer.baseAddress!)
    }
}

// MARK: - 运行时

final class NodeRuntime: ObservableObject {

    enum State: String {
        case idle, preparing, launching, ready, failed, exited

        var label: String {
            switch self {
            case .idle: return "未启动"
            case .preparing: return "准备中"
            case .launching: return "启动中（等待 serverStarted）"
            case .ready: return "已就绪"
            case .failed: return "失败"
            case .exited: return "Node 已退出"
            }
        }
    }

    // 下面这些 @Published 只在主线程改（所有改动都经过 refreshHealthBox / onMain 的路径）

    @Published private(set) var state: State = .idle
    @Published private(set) var bridgePort: UInt16 = 0
    @Published private(set) var serviceBase: String?
    @Published private(set) var nodeVersion: String?
    @Published private(set) var nodeArch: String?
    @Published private(set) var nodePid: Int?
    @Published private(set) var bootstrapPath: String?
    @Published private(set) var compileCachePath: String?
    @Published private(set) var dataRootPath: String?
    @Published private(set) var lastError: String?
    @Published private(set) var launchStartedAt: Date?
    @Published private(set) var readyAt: Date?
    @Published private(set) var launchCount = 0
    /// 当前启动的是哪个源（P4 起 HomeView 靠它去 /config 拉站点）
    @Published private(set) var activeSourceId = ""

    // 源主动推给用户的两样东西（见 RootView）
    @Published private(set) var toastText: String?
    @Published private(set) var webPanelURL: URL?

    func clearToast() { toastText = nil }
    func closeWebPanel() { webPanelURL = nil }

    /// 手动打开源的配置中心（源自带的网页面板：登录夸克/百度等网盘就在里面）
    /// 兜底用：万一源发来的 openInternalWebview 消息没送达（例如 App 刚被挂起过），用户也能自己点开
    @discardableResult
    func openWebPanel(path: String = "/website") -> Bool {
        guard let base = serviceBase, let url = URL(string: base + path) else {
            CatyLog.shared.warn("bridge", "还没有服务地址，打不开配置中心")
            return false
        }
        CatyLog.shared.info("ui", "手动打开源配置中心：\(url.absoluteString)")
        webPanelURL = url
        return true
    }

    /// iOS 上不能重启 Node（见文件头第 1 条）
    let canRelaunch = false

    private let healthBox = Locked<[String: Any]>(["ok": false, "state": "idle"])
    private var bridge: BridgeServer?
    private var nodeThread: Thread?
    private var watchdog: Timer?

    var startupSeconds: Double? {
        guard let launchStartedAt, let readyAt else { return nil }
        return readyAt.timeIntervalSince(launchStartedAt)
    }

    // MARK: - P2 自检入口：启动内置打桩源

    func bootstrapStub() {
        guard launchCount == 0 else {
            CatyLog.shared.warn("runtime", "已经启动过一次 Node（iOS 上不可重入），本次请求忽略")
            return
        }
        do {
            let stub = try BootstrapLoader.installStubBundle()
            let bootstrap = try BootstrapLoader.installBootstrap()
            launch(sourceId: stub.sourceId,
                   bootstrap: bootstrap,
                   index: stub.indexFile,
                   config: stub.configFile,
                   dataRoot: stub.dataRoot)
        } catch {
            fail("准备打桩源失败：\(error.localizedDescription)")
        }
    }

    // MARK: - P3：用真实 bundle 启动

    /// 真实源（P3 起）：index/config 来自 BundleStore 的 active 目录
    func launch(sourceId: String, index: URL, config: URL, dataRoot: URL) {
        guard launchCount == 0 else {
            CatyLog.shared.warn("runtime", "Node 已经启动过一次（iOS 不可重入），本次新源要重启 App 才生效")
            return
        }
        do {
            let bootstrap = try BootstrapLoader.installBootstrap()
            launch(sourceId: sourceId, bootstrap: bootstrap, index: index, config: config, dataRoot: dataRoot)
        } catch {
            fail("准备 bootstrap 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 启动

    private func launch(sourceId: String, bootstrap: URL, index: URL, config: URL, dataRoot: URL) {
        activeSourceId = sourceId
        launchCount += 1
        launchStartedAt = Date()
        state = .preparing
        dataRootPath = dataRoot.path
        bootstrapPath = bootstrap.path
        CatyLog.shared.info("runtime", "开始启动：source=\(sourceId)")
        CatyLog.shared.info("runtime", "数据目录 \(dataRoot.path)")

        // ---- 环境变量（必须在 node_start 之前）
        let compileDir = (try? CatyPaths.compileCacheDir())?.path
        compileCachePath = compileDir
        if let compileDir {
            setenv("NODE_COMPILE_CACHE", compileDir, 1)
        }
        // 容器路径含 UUID，重装后会变 —— 不加 portable 会静默全部 miss
        setenv("NODE_COMPILE_CACHE_PORTABLE", "1", 1)

        // 内存上限：按机型总内存的三分之一给，封顶 1.5 GB，避免被 iOS jetsam 杀进程
        let physical = ProcessInfo.processInfo.physicalMemory
        let maxOldSpaceMB = max(384, min(1536, Int(physical / 1024 / 1024 / 3)))
        setenv("NODE_OPTIONS", "--max-old-space-size=\(maxOldSpaceMB)", 1)
        CatyLog.shared.info("runtime", "NODE_OPTIONS=--max-old-space-size=\(maxOldSpaceMB)（本机 \(physical / 1024 / 1024)MB）")

        // bundle 约定（bootstrap.js 里还会再设一遍，值一致）
        setenv("CATVOD_DISABLE_AUTOSTART", "1", 1)
        setenv("HOST", "127.0.0.1", 1)
        setenv("PORT", "0", 1)
        setenv("DEV_HTTP_PORT", "0", 1)
        setenv("HOME", dataRoot.path, 1)

        // ---- /msg 桥
        let token = NodeRuntime.randomToken()
        let bridge = BridgeServer(token: token)
        bridge.healthProvider = { [weak self] in self?.healthBox.get() ?? ["ok": false] }
        bridge.onMessage = { [weak self] message in self?.handle(message) }
        self.bridge = bridge

        bridge.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.fail("bridge 启动失败：\(error.localizedDescription)")
            case .success(let port):
                self.bridgePort = port
                CatyLog.shared.info("bridge", "已监听 127.0.0.1:\(port)（token=<redacted len=\(token.count)>）")
                self.startNodeThread(bootstrap: bootstrap, index: index, config: config,
                                     dataRoot: dataRoot, token: token, port: port)
            }
        }
        refreshHealthBox()
    }

    private func startNodeThread(bootstrap: URL, index: URL, config: URL,
                                 dataRoot: URL, token: String, port: UInt16) {
        state = .launching
        refreshHealthBox()

        let arguments = ["node", bootstrap.path, index.path, config.path, dataRoot.path, String(port), token]
        CatyLog.shared.info("runtime",
            "node_start：node bootstrap.js <index.js> <index.config.js> <dataRoot> \(port) <redacted len=\(token.count)>")

        NodeRuntime.redirectStdioToLog()

        let thread = Thread { [weak self] in
            CatyLog.shared.info("runtime", "Node 线程已启动 → 调用 node_start（会一直阻塞到 Node 退出）")
            let code = withCArguments(arguments) { argc, argv in
                node_start(argc, argv)
            }
            CatyLog.shared.warn("runtime", "node_start 返回了，退出码 = \(code)")
            DispatchQueue.main.async { self?.nodeDidExit(code: code) }
        }
        thread.name = "caty.node"
        // 默认线程栈只有 512 KB，对 V8 太小；4 MB 与桌面 Node 的观感一致
        thread.stackSize = 4 * 1024 * 1024
        thread.start()
        nodeThread = thread
        startWatchdog()
    }

    // MARK: - 桥消息（主线程）

    private func handle(_ message: BridgeServer.Message) {
        switch message.action {
        case "serverStarted":
            let address = message.opt["address"] as? String
            serviceBase = address
            nodeVersion = message.opt["version"] as? String
            nodeArch = message.opt["arch"] as? String
            nodePid = (message.opt["pid"] as? NSNumber)?.intValue
            readyAt = Date()
            state = .ready
            watchdog?.invalidate()
            watchdog = nil
            let elapsed = startupSeconds.map { String(format: "%.2fs", $0) } ?? "?"
            CatyLog.shared.info("bridge",
                "serverStarted → \(address ?? "(无地址)")  node=\(nodeVersion ?? "?") arch=\(nodeArch ?? "?") pid=\(nodePid.map(String.init) ?? "?") 首屏耗时=\(elapsed)")
            refreshHealthBox()

        case "nodeError":
            let detail = message.opt["message"] as? String ?? "(无内容)"
            fail("nodeError：\(detail)")

        case "toast":
            let text = message.opt["message"] as? String
                ?? message.opt["msg"] as? String
                ?? message.opt["text"] as? String
                ?? "(源发来一条提示)"
            toastText = text
            CatyLog.shared.info("bridge", "源提示：\(text)（参数键=\(message.opt.keys.sorted().joined(separator: ","))）")

        case "openInternalWebview":
            let raw = message.opt["url"] as? String ?? message.opt["link"] as? String ?? ""
            if !raw.isEmpty, let url = URL(string: raw) {
                webPanelURL = url
                CatyLog.shared.info("bridge", "源要求打开内置网页：\(raw)")
            } else {
                CatyLog.shared.warn("bridge", "openInternalWebview 未带 url（参数键=\(message.opt.keys.sorted().joined(separator: ","))）")
            }

        default:
            CatyLog.shared.info("bridge",
                "收到消息 action=\(message.action)（参数键=\(message.opt.keys.sorted().joined(separator: ","))）")
        }
    }

    private func nodeDidExit(code: Int32) {
        watchdog?.invalidate()
        watchdog = nil
        serviceBase = nil
        if state != .failed {
            state = .exited
            lastError = "Node 进程已退出（code=\(code)）。iOS 上 node_start 不可重入，请重启 App 后重试。"
            CatyLog.shared.error("runtime", lastError ?? "")
        }
        refreshHealthBox()
    }

    private func fail(_ message: String) {
        watchdog?.invalidate()
        watchdog = nil
        lastError = message
        state = .failed
        CatyLog.shared.error("runtime", message)
        refreshHealthBox()
    }

    /// 等 serverStarted 期间每 10s 打一条心跳，超 90s 判失败（节点可能仍在后台慢启动）
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.state == .launching, let started = self.launchStartedAt else { return }
            let elapsed = Int(Date().timeIntervalSince(started))
            CatyLog.shared.warn("runtime", "运行时准备中（已 \(elapsed)s）")
            if elapsed >= 90 {
                self.fail("等待 serverStarted 超时（90s）。看日志分辨：① 有 [stub] 输出但没有 serverStarted → Node 起了，是 /msg 回报没到宿主；② 一行 Node 输出都没有 → node_start 根本没跑起来")
            }
        }
    }

    // MARK: - 健康信息（跨线程）

    private func refreshHealthBox() {
        var payload: [String: Any] = [
            "ok": state == .ready,
            "app": "Caty",
            "state": state.rawValue,
            "bridgePort": Int(bridgePort),
        ]
        if let serviceBase { payload["service"] = serviceBase }
        if let nodeVersion { payload["node"] = nodeVersion }
        if let nodeArch { payload["arch"] = nodeArch }
        if let nodePid { payload["pid"] = nodePid }
        if let compileCachePath { payload["compileCache"] = compileCachePath }
        if let seconds = startupSeconds { payload["startupSec"] = (seconds * 100).rounded() / 100 }
        if let lastError { payload["lastError"] = lastError }
        healthBox.set(payload)
    }

    // MARK: - 客户端侧请求（给自检界面用；P4 起换成正式的站点请求层）

    @MainActor
    func probe(_ path: String) async -> String {
        guard let base = serviceBase, let url = URL(string: base + path) else {
            return "还没有服务地址：等状态变成「已就绪」再点（当前：\(state.label)）"
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("okhttp/3.15.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(decoding: data, as: UTF8.self)
            let clipped = text.count > 700 ? String(text.prefix(700)) + "…（\(text.count)B）" : text
            return "HTTP \(code)\n\(clipped)"
        } catch {
            return "请求失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 工具

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 采集 Node 的 console 输出

    private static var stdioRedirected = false
    private static var nodeStdioHandle: FileHandle?

    /// 把 fd 1/2 重定向到管道，Node 的 console.log 就进了 App 日志。
    /// 注意：重定向之后本进程所有 stdout 写入都会被当成 Node 输出采集，
    /// 所以 CatyLog 绝不写 stdout（这是刻意设计，不要改成 print）。
    private static func redirectStdioToLog() {
        guard !stdioRedirected else { return }
        stdioRedirected = true

        var fileDescriptors: [Int32] = [0, 0]
        guard pipe(&fileDescriptors) == 0 else {
            CatyLog.shared.warn("runtime", "pipe() 失败：Node 的 console 输出不会进日志（不影响启动）")
            return
        }
        let readFD = fileDescriptors[0]
        let writeFD = fileDescriptors[1]
        dup2(writeFD, STDOUT_FILENO)
        dup2(writeFD, STDERR_FILENO)
        close(writeFD)

        let handle = FileHandle(fileDescriptor: readFD, closeOnDealloc: false)
        nodeStdioHandle = handle
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                CatyLog.shared.log(.info, "node", line)
            }
        }
    }
}
