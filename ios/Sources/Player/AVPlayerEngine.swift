//
//  AVPlayerEngine.swift
//  播放器抽象（P4：先把 AVPlayer 跑通；P6 加 libmpv 内核）
//
//  为什么先 AVPlayer：HLS/MP4 覆盖大部分片源，且零依赖、零编译风险。
//  已知短板（见 docs/03 报错表第 15 条）：mkv、部分编码（HEVC/AV1 的某些封装）、软解字幕要等 libmpv。
//
//  2026-10-10 补：用户问"有些视频播不了是不是播放器的问题"——是。
//  这里把**失败原因尽量说清楚**（item 的 error + errorLog 的最后一条 + 后缀判断），
//  这样既能当场分辨"源给的地址就是坏的"和"系统内核不支持这种封装"，
//  也让以后接 mpv 内核时有个统一的诊断出口（`lastError` / `formatHint`）。
//

import AVKit
import Combine

final class AVPlayerEngine: ObservableObject {

    let player = AVPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTitle: String?
    @Published private(set) var currentURL: URL?
    @Published private(set) var lastError: String?
    /// 给用户看的"为什么播不了"（例：这种封装系统内核不支持）
    @Published private(set) var formatHint: String?

    /// 0.5–2.0，P5 做倍速菜单时用
    @Published var rate: Float = 1.0

    private var observations: [NSKeyValueObservation] = []

    init() {
        player.actionAtItemEnd = .pause

        // 只观察非可选属性（KVO 的 keypath 更稳）
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            let error = player.currentItem?.error?.localizedDescription
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPlaying = playing
                if let error, error != self.lastError {
                    self.setError(error)
                }
            }
        })
    }

    deinit {
        observations.forEach { $0.invalidate() }
    }

    /// headers 走 AVURLAsset 的私有键（业内通用做法），防盗链源会用到
    func load(url: URL, headers: [String: String] = [:], title: String? = nil) {
        currentTitle = title
        currentURL = url
        lastError = nil
        formatHint = Self.hint(for: url)
        prepareAudioSession()

        let asset: AVURLAsset
        if headers.isEmpty {
            asset = AVURLAsset(url: url)
        } else {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            CatyLog.shared.info("player", "带 \(headers.count) 个请求头播放（防盗链）")
        }
        let item = AVPlayerItem(asset: asset)
        // 音画同步：让系统用时间域算法处理变速，避免变调/错位
        item.audioTimePitchAlgorithm = .timeDomain
        observe(item: item)
        player.replaceCurrentItem(with: item)
        CatyLog.shared.info("player", "开始播放：\(url.absoluteString)")
        play()
    }

    /// 单个条目的失败要单独看（player 的 error 常常是 nil，真正的原因在 item 上）
    private func observe(item: AVPlayerItem) {
        observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let basic = item.error?.localizedDescription ?? "未知错误"
            let detail = item.errorLog()?.events.last?.errorLogMessage
            DispatchQueue.main.async {
                guard let self else { return }
                self.setError(detail.map { "\(basic)（\($0)）" } ?? basic)
            }
        })
    }

    private func setError(_ message: String) {
        lastError = message
        CatyLog.shared.error("player", "AVPlayer 出错：\(message)")
    }

    /// 按后缀/URL 先给一句人话（系统内核 + 常见封装）
    private static func hint(for url: URL) -> String? {
        let lowered = url.absoluteString.lowercased()
        if lowered.contains(".mkv") {
            return "这是 MKV 封装，系统内核（AVPlayer）基本解不了 → 需要 mpv 内核（已排期，见 README「下一步」）"
        }
        if lowered.contains(".ts") || lowered.contains(".m2ts") {
            return "TS/M2TS 封装系统内核支持有限，播不了就换线路试试"
        }
        return nil
    }

    /// 播放前把音频会话配好（顺带支持后台音频）
    private func prepareAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            CatyLog.shared.warn("player", "音频会话配置失败：\(error.localizedDescription)")
        }
        #endif
    }

    func play() {
        player.play()
        if rate != 1.0 { player.rate = rate }
    }

    func pause() {
        player.pause()
    }

    func toggle() {
        if player.timeControlStatus == .playing { pause() } else { play() }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentTitle = nil
        currentURL = nil
    }
}
