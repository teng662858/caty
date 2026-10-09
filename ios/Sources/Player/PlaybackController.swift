//
//  PlaybackController.swift
//  播放内核的统一入口（P6）：在"系统 AVPlayer"和"libmpv"之间选一个、并做自动回退
//
//  为什么要这一层：PlayerView / 全屏播放 / 手势都要能"不知道底下用的是哪个内核"。
//  选择逻辑（用户设置 → PlayerKernelPreference）：
//    · 自动（默认）：明显是 MKV 的直接用 mpv；其余先用系统内核，
//      一旦系统内核报错（典型：mkv/2160p 解不了）就**自动切 mpv 重播同一个地址**，并给用户一条提示。
//    · 系统内核：只用 AVPlayer（省电、起播快）
//    · mpv 内核：只用 libmpv（字幕/10bit/软解）
//

import Foundation
import Combine
import AVFoundation

enum PlayerKernelPreference: String, CaseIterable, Identifiable {
    case auto, system, mpv

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "自动（推荐）"
        case .system: return "系统内核"
        case .mpv: return "mpv 内核"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "MP4/HLS 走系统内核（省电）；MKV/播不了时自动换 mpv"
        case .system: return "只用系统 AVPlayer：省电、起播快，但不支持 MKV/10bit 字幕"
        case .mpv: return "只用 libmpv：MKV、2160p、内嵌字幕、可软解，费电一些"
        }
    }

    static func from(_ raw: String) -> PlayerKernelPreference {
        PlayerKernelPreference(rawValue: raw) ?? .auto
    }
}

final class PlaybackController: ObservableObject {

    enum Active: String {
        case system, mpv

        var label: String { self == .system ? "系统内核" : "mpv 内核" }
    }

    @Published private(set) var active: Active = .system
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var buffering = false
    /// 最近一次采样到 position 的时刻（弹幕要按"位置 + 过去的时间"外推，才跟得上画面）
    private(set) var positionUpdatedAt = Date()
    /// 画面的宽高比（宽/高）。竖屏短剧 ≈ 0.56，横屏 ≈ 1.78；拿不到就 nil 走 16:9
    @Published private(set) var videoAspect: Double?
    @Published private(set) var errorText: String?
    /// 状态提示（例如"系统内核播不了，已自动切 mpv"）
    @Published private(set) var kernelNote: String?
    @Published private(set) var currentTitle: String?

    let av = AVPlayerEngine()
    let mpv = MPVPlayerEngine()

    /// 播完/播到头（用来接自动下一集）
    var onEnded: (() -> Void)?

    private var request: (url: URL, headers: [String: String], title: String?)?
    private var preference: PlayerKernelPreference = .auto
    private var cancellables = Set<AnyCancellable>()
    private var ticker: Timer?
    private var endedByMPV = false

    init() {
        // 系统内核失败 → 自动模式下换成 mpv（用户看到的就是"卡一下之后能播了"）
        av.$lastError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self else { return }
                self.errorText = message
                guard self.preference == .auto, self.active == .system, let request = self.request else { return }
                CatyLog.shared.warn("player", "系统内核播不了（\(message)）→ 自动切 mpv")
                self.kernelNote = "系统内核播不了，已自动切换 mpv 内核"
                self.start(kernel: .mpv, request: request)
            }
            .store(in: &cancellables)

        mpv.$lastError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in self?.errorText = message }
            .store(in: &cancellables)

        mpv.ended
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handleEnded() }
            .store(in: &cancellables)

        av.ended
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handleEnded() }
            .store(in: &cancellables)

        startTicker()
    }

    deinit {
        ticker?.invalidate()
    }

    // MARK: - 对外接口

    func update(preference: PlayerKernelPreference, rate: Double) {
        self.preference = preference
        av.rate = Float(rate)
        mpv.setRate(rate)
    }

    var videoAspectReady: Bool { active == .system ? av.currentURL != nil : mpv.currentURL != nil }

    /// 开始播一个地址（内核由设置 + 地址特征决定）
    func load(url: URL, headers: [String: String] = [:], title: String? = nil) {
        let request = (url: url, headers: headers, title: title)
        self.request = request
        errorText = nil
        kernelNote = nil
        endedByMPV = false
        position = 0
        duration = 0
        start(kernel: pickKernel(for: url), request: request)
    }

    func stop() {
        av.stop()
        mpv.stop()
        request = nil
    }

    func play() {
        active == .system ? av.play() : mpv.play()
    }

    func pause() {
        active == .system ? av.pause() : mpv.pause()
    }

    func toggle() {
        active == .system ? av.toggle() : mpv.toggle()
    }

    func seek(to seconds: Double) {
        position = seconds
        active == .system ? av.seek(to: seconds) : mpv.seek(to: seconds)
    }

    func setRate(_ value: Double) {
        av.rate = Float(value)
        mpv.setRate(value)
        active == .system ? av.play() : mpv.play()
    }

    /// 直播流（没有总时长但已经在走）：进度条要隐藏、也不能"自动下一集"
    var isLive: Bool { duration <= 0 && position > 3 }

    // MARK: - 内核选择

    private func pickKernel(for url: URL) -> Active {
        switch preference {
        case .system: return .system
        case .mpv: return .mpv
        case .auto:
            // 明显系统内核啃不动的（MKV/TS），直接用 mpv，省掉"先失败再切"的等待
            let lowered = url.absoluteString.lowercased()
            if lowered.contains(".mkv") || lowered.contains(".ts?") || lowered.hasSuffix(".ts") {
                return .mpv
            }
            return .system
        }
    }

    private func start(kernel: Active, request: (url: URL, headers: [String: String], title: String?)) {
        active = kernel
        currentTitle = request.title
        switch kernel {
        case .system:
            av.stop()
            av.load(url: request.url, headers: request.headers, title: request.title)
        case .mpv:
            av.stop()
            mpv.load(url: request.url, headers: request.headers, title: request.title)
        }
        CatyLog.shared.info("player", "当前内核：\(kernel.label)（\(request.url.absoluteString.prefix(60))…）")
        sample()
    }

    /// 给 UI 手动切内核用（播放页上的"换内核再试一次"）
    @discardableResult
    func switchKernel(to kernel: Active) -> Bool {
        guard let request else { return false }
        kernelNote = nil
        errorText = nil
        start(kernel: kernel, request: request)
        return true
    }

    // MARK: - 状态汇总（0.35s 采样一次，UI 只看这里）

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    private func sample() {
        positionUpdatedAt = Date()
        sampleAspect()
        switch active {
        case .system:
            isPlaying = av.isPlaying
            position = av.player.currentTime().seconds.isFinite ? max(0, av.player.currentTime().seconds) : position
            if let total = av.player.currentItem?.duration.seconds, total.isFinite, total > 0 {
                duration = total
            }
            buffering = av.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            if let error = av.lastError { errorText = error }
        case .mpv:
            isPlaying = mpv.isPlaying
            position = mpv.position
            duration = mpv.duration
            buffering = mpv.buffering
            if let error = mpv.lastError { errorText = error }
        }
    }

    private func sampleAspect() {
        var aspect: Double?
        switch active {
        case .system:
            let size = av.player.currentItem?.presentationSize ?? .zero
            if size.width > 1, size.height > 1 { aspect = Double(size.width / size.height) }
        case .mpv:
            let width = mpv.videoWidth
            let height = mpv.videoHeight
            if width > 1, height > 1 { aspect = Double(width) / Double(height) }
        }
        if let aspect, abs((videoAspect ?? 0) - aspect) > 0.01 {
            videoAspect = aspect
        }
    }

    /// 竖屏画面（短剧/直播竖屏）——进全屏时不能硬转横屏
    var isPortraitVideo: Bool { (videoAspect ?? 1.78) < 1.05 }

    private func handleEnded() {
        onEnded?()
    }
}
