//
//  AVPlayerEngine.swift
//  播放器抽象（P4：先把 AVPlayer 跑通；P6 再考虑 libmpv）
//
//  为什么先 AVPlayer：HLS/MP4 覆盖大部分片源，且零依赖、零编译风险。
//  已知短板（见 docs/03 报错表第 15 条）：mkv、部分编码、软解字幕要等 libmpv。
//

import AVKit
import Combine

final class AVPlayerEngine: ObservableObject {

    let player = AVPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTitle: String?
    @Published private(set) var currentURL: URL?
    @Published private(set) var lastError: String?

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
                    self.lastError = error
                    CatyLog.shared.error("player", "AVPlayer 出错：\(error)")
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

        let asset: AVURLAsset
        if headers.isEmpty {
            asset = AVURLAsset(url: url)
        } else {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            CatyLog.shared.info("player", "带 \(headers.count) 个请求头播放（防盗链）")
        }
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        CatyLog.shared.info("player", "开始播放：\(url.absoluteString)")
        play()
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
