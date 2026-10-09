//
//  MPVPlayerEngine.swift
//  libmpv 播放内核（P6）—— 解决系统 AVPlayer 播不了的：MKV 封装、2160p 高码率、
//  部分 HEVC/AV1、内嵌/外挂字幕、软解回退；10-bit/HDR 也走 libplacebo 色调映射。
//
//  渲染方式（照 MPVKit 官方 demo 的做法，最简单也最稳）：
//    我们自己建一个 CAMetalLayer，通过 `wid` 选项交给 mpv，
//    mpv 用 `vo=gpu-next` + `gpu-api=vulkan` + `gpu-context=moltenvk` **自己渲染进这个图层**。
//    → 不需要我们写渲染循环/着色器；字幕、缩放、HDR 交给 mpv/libplacebo。
//    （另一条路是 OpenGL ES 的 render API，但 MPVKit 明确写了它 10-bit 会渲染错，所以不用。）
//
//  ⚠️ 踩过/已知的坑（都写在对应位置）：
//    · MoltenVK 会把 drawableSize 设成 1x1 来"强制结束呈现" → MetalLayer 里挡住
//    · HDR 的 wantsExtendedDynamicRangeContent 必须回主线程设，否则不生效
//    · App 切后台再回来容易黑屏 → 切后台时 `vid=no`，回前台再 `vid=auto`（demo 同款 workaround）
//    · ytdl=no：iOS 上没有外部进程，别让 mpv 去找 yt-dlp
//

import Foundation
import Combine
import UIKit
import QuartzCore
import Libmpv

/// MoltenVK 需要的两个 workaround（照 MPVKit demo）
final class MPVVideoLayer: CAMetalLayer {

    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue }
            }
        }
    }
}

final class MPVPlayerEngine: ObservableObject {

    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTitle: String?
    @Published private(set) var currentURL: URL?
    @Published private(set) var lastError: String?
    @Published private(set) var buffering = false
    /// 播完（用来接"自动下一集"）
    let ended = PassthroughSubject<Void, Never>()

    /// 交给 mpv 渲染的那个图层（视图把它挂到自己的 layer 上）
    let metalLayer: MPVVideoLayer = {
        let layer = MPVVideoLayer()
        layer.framebufferOnly = true
        layer.backgroundColor = UIColor.black.cgColor
        layer.contentsScale = UIScreen.main.nativeScale
        return layer
    }()

    var rate: Float = 1.0
    /// 拉流和解码用的自定义请求头（防盗链源会给 Referer/UA）
    private var headerFields: [String: String] = [:]

    private var mpv: OpaquePointer?
    private var prepared = false
    private var positionTimer: Timer?
    private var endFileReasonEof = false
    private let eventQueue = DispatchQueue(label: "caty.mpv.events", qos: .userInitiated)

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(willResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        positionTimer?.invalidate()
        if let mpv {
            mpv_terminate_destroy(mpv)
        }
    }

    // MARK: - 生命周期

    /// 建 mpv 实例。必须在视图把 metalLayer 挂上之后调用（mpv 会立刻开始用这个图层）。
    func prepare() {
        guard !prepared else { return }
        prepared = true

        guard let handle = mpv_create() else {
            lastError = "mpv_create 失败（libmpv 没起来）"
            CatyLog.shared.error("player", lastError ?? "")
            return
        }
        mpv = handle

        // 日志：只在 Debug 里要 verbose；Release 静默（但保留 error 级，方便排错）
        setLogLevel("error")

        // ---- 渲染：把图层交给 mpv，MoltenVK 负责画
        var layerPointer = Int64(Int(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque()))
        setOption("wid", int64: &layerPointer)
        setOption("vo", "gpu-next")
        setOption("gpu-api", "vulkan")
        setOption("gpu-context", "moltenvk")
        // 硬件解码；码流不支持时 mpv 自己回退到软解（auto-safe 不会选不安全的解码器）
        setOption("hwdec", "auto-safe")
        setOption("video-rotate", "no")
        // 目标色域：HDR 内容做色调映射（不打开系统 EDR 直通，避免 HDR 屏闪）
        setOption("target-colorspace-hint", "no")

        // ---- 其它：别去碰宿主环境
        setOption("config", "no")
        setOption("load-scripts", "no")
        setOption("osc", "no")
        setOption("input-default-bindings", "no")
        setOption("input-vo-keyboard", "no")
        setOption("ytdl", "no")            // iOS 上没有 yt-dlp 进程
        setOption("terminal", "no")
        setOption("audio-client-name", "Caty")
        setOption("keep-open", "no")
        setOption("screenshot-directory", NSTemporaryDirectory())
        // 字幕：优先中文字幕，找不到就用第一个
        setOption("subs-match-os-language", "yes")
        setOption("subs-fallback", "yes")
        setOption("sub-font-size", "44")
        // 网络：默认 cache=auto 对网络流已经够；给个宽松一点的超时，别一卡就断
        setOption("network-timeout", "30")
        setOption("force-seekable", "no")

        let code = mpv_initialize(handle)
        guard code >= 0 else {
            lastError = "mpv_initialize 失败：\(Self.errorText(code))"
            CatyLog.shared.error("player", lastError ?? "")
            return
        }
        CatyLog.shared.info("player", "libmpv 就绪：\(Self.clientVersionText())")

        startPolling()
        startEventLoop()
    }

    // MARK: - 播放控制

    func load(url: URL, headers: [String: String] = [:], title: String? = nil) {
        prepare()
        guard let mpv else { return }
        currentURL = url
        currentTitle = title
        lastError = nil
        endFileReasonEof = false

        headerFields = headers
        if !headers.isEmpty {
            // mpv 的格式是 "Key: Value, Key2: Value2"
            let fields = headers.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            mpv_set_property_string(mpv, "http-header-fields", fields)
            CatyLog.shared.info("player", "mpv 带 \(headers.count) 个请求头（防盗链）")
        } else {
            mpv_set_property_string(mpv, "http-header-fields", "")
        }

        command("loadfile", args: [url.absoluteString, "replace"])
        if rate != 1.0 {
            mpv_set_property_string(mpv, "speed", String(format: "%g", rate))
        }
        CatyLog.shared.info("player", "mpv 开始播放：\(url.absoluteString)")
        startPollingInstant()
    }

    func play() {
        guard let mpv else { return }
        var flag: Int32 = 0
        mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
    }

    func pause() {
        guard let mpv else { return }
        var flag: Int32 = 1
        mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: Double) {
        command("seek", args: [String(format: "%.3f", seconds), "absolute"])
    }

    func setRate(_ value: Double) {
        rate = Float(value)
        guard let mpv else { return }
        mpv_set_property_string(mpv, "speed", String(format: "%g", value))
    }

    func stop() {
        command("stop", args: [])
        currentURL = nil
        currentTitle = nil
        positionTimer?.invalidate()
        positionTimer = nil
    }

    // MARK: - mpv 小工具

    private func setOption(_ name: String, _ value: String) {
        guard let mpv else { return }
        mpv_set_option_string(mpv, name, value)
    }

    private func setOption(_ name: String, int64 value: inout Int64) {
        guard let mpv else { return }
        mpv_set_option(mpv, name, MPV_FORMAT_INT64, &value)
    }

    private func setLogLevel(_ level: String) {
        guard let mpv else { return }
        mpv_request_log_messages(mpv, level)
    }

    /// mpv_command 的 C 字符串数组封装
    private func command(_ name: String, args: [String]) {
        guard let mpv else { return }
        var strings: [String?] = [name] + args
        strings.append(nil)
        var cArgs: [UnsafePointer<CChar>?] = strings.map { $0.map { UnsafePointer(strdup($0)) } }
        defer {
            for pointer in cArgs where pointer != nil {
                free(UnsafeMutablePointer(mutating: pointer!))
            }
        }
        let code = mpv_command(mpv, &cArgs)
        if code < 0 {
            CatyLog.shared.warn("player", "mpv 命令 \(name) 失败：\(Self.errorText(code))")
        }
    }

    private func getDouble(_ name: String) -> Double {
        guard let mpv else { return 0 }
        var value = Double()
        guard mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value) >= 0 else { return 0 }
        return value
    }

    private func getFlag(_ name: String) -> Bool {
        guard let mpv else { return false }
        var value: Int32 = 0
        guard mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &value) >= 0 else { return false }
        return value != 0
    }

    private static func errorText(_ code: Int32) -> String {
        guard let pointer = mpv_error_string(code) else { return "code \(code)" }
        return String(cString: pointer)
    }

    private static func clientVersionText() -> String {
        let version = mpv_client_api_version()
        return "client api \(version >> 16).\(version & 0xffff)"
    }

    // MARK: - 状态轮询（主线程，0.4s）

    private func startPolling() {
        positionTimer?.invalidate()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func startPollingInstant() {
        if positionTimer == nil { startPolling() }
        poll()
    }

    private func poll() {
        guard mpv != nil, currentURL != nil else { return }
        let time = getDouble("time-pos")
        if time.isFinite, time >= 0 { position = time }
        let total = getDouble("duration")
        if total.isFinite, total > 0 { duration = total }
        isPlaying = !getFlag("pause") && !getFlag("eof-reached")
        buffering = getFlag("paused-for-cache")
    }

    // MARK: - 事件循环（后台线程）

    private func startEventLoop() {
        guard let mpv else { return }
        let handle = mpv
        eventQueue.async { [weak self] in
            while self != nil {
                guard let event = mpv_wait_event(handle, 0.5) else { continue }
                let id = event.pointee.event_id
                if id == MPV_EVENT_NONE { continue }
                if id == MPV_EVENT_SHUTDOWN { return }
                if id == MPV_EVENT_END_FILE {
                    let data = event.pointee.data
                    var reason = Int32(0)
                    if let data {
                        let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                        reason = endFile.reason
                    }
                    CatyLog.shared.info("player", "mpv 播放结束（reason=\(reason)）")
                    if reason == MPV_END_FILE_REASON_EOF || reason == MPV_END_FILE_REASON_ERROR {
                        DispatchQueue.main.async {
                            self?.isPlaying = false
                            self?.ended.send()
                        }
                    }
                }
                if id == MPV_EVENT_LOG_MESSAGE, let data = event.pointee.data {
                    let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                    if let text = message.text, let prefix = message.prefix {
                        let line = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
                        let tag = String(cString: prefix)
                        if !line.isEmpty {
                            CatyLog.shared.info("mpv", "[\(tag)] \(line)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 前后台切换（黑屏 workaround）

    @objc private func willResignActive() {
        // 挂起后回前台 MoltenVK 常剩一个黑画面：先关视频轨，回前台再打开
        guard let mpv, currentURL != nil else { return }
        mpv_set_property_string(mpv, "vid", "no")
    }

    @objc private func didBecomeActive() {
        guard let mpv, currentURL != nil else { return }
        mpv_set_property_string(mpv, "vid", "auto")
    }
}
