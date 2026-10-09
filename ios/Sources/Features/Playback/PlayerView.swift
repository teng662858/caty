//
//  PlayerView.swift
//  播放页（P5 起；P6 加内核切换 + 手势 + 直播适配）
//
//  返回手势：在画面上**向下滑**关闭、**从屏幕左边缘往右滑**返回（全屏弹出没有系统返回手势）。
//
//  P6 手势（跟着画面走，左侧上下 = 亮度、右侧上下 = 音量、横向 = 快进/快退、长按 = 2 倍速）：
//   · 只在**没进全屏**时的画面区域生效，和"下滑关闭"用同一套拖拽识别（先判方向再决定动作）
//   · 亮度用系统亮度（UIScreen.brightness），音量用 MPVolumeView 的滑块（iOS 没有公开的音量 setter）
//   · 动作过程中画面中间显示一个 HUD（图标 + 当前值/时间），松手 0.8 秒后消失
//

import SwiftUI
import AVKit
import MediaPlayer
import UIKit

struct PlayerView: View {

    let request: PlayRequest
    let client: NodeClient?

    @StateObject private var controller = PlaybackController()
    @ObservedObject private var library = LibraryStore.shared

    @State private var index: Int
    @State private var rate: Double
    @State private var resolving = true
    @State private var errorText: String?
    /// 跟手位移：下滑关闭 / 左边缘返回各一个（用于拖的时候页面跟着动）
    @State private var dragY: CGFloat = 0
    @State private var dragX: CGFloat = 0
    /// 全屏（横屏）播放
    @State private var showFullscreen = false
    /// 手势 HUD（亮度/音量/快进提示）
    @State private var hud: GestureHUD?
    /// 音量（自己记住，因为 iOS 不给读系统音量以外的写入口）
    @State private var volume: Float = 0.5
    @State private var brightness: CGFloat = UIScreen.main.brightness
    @State private var volumeSlider: UISlider?
    @State private var longPressRate = false
    /// 弹幕（P6）：从源里取这一集的弹幕，Canvas 画在画面上
    @State private var danmaku: [DanmakuComment] = []
    @State private var danmakuEnabled: Bool

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var item: VodItem { request.item }
    private var episodes: [Episode] { request.episodes }
    private var episode: Episode? {
        guard index >= 0, index < episodes.count else { return nil }
        return episodes[index]
    }

    init(request: PlayRequest, client: NodeClient?) {
        self.request = request
        self.client = client
        _index = State(initialValue: request.index)
        _rate = State(initialValue: LibraryStore.shared.settings.rate)
        _danmakuEnabled = State(initialValue: LibraryStore.shared.settings.danmakuEnabled)
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                videoArea
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.spacingL) {
                        infoBlock
                        progressRow
                        controlBar
                        episodeStrip
                    }
                    .padding(Theme.padding)
                }
            }
            .navigationTitle(episode?.name ?? item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { close() } label: {
                        Label("返回", systemImage: "chevron.down")
                    }
                }
            }
        }
        // 拖动的反馈：两个方向都只允许"正向"位移，看起来就像页面被拽出去
        .offset(y: max(0, dragY))
        .offset(x: max(0, dragX))
        .simultaneousGesture(backSwipeGesture)
        .fullScreenCover(isPresented: $showFullscreen) {
            FullscreenPlayerView(controller: controller,
                                 episodes: episodes,
                                 currentIndex: index,
                                 rate: rate,
                                 isLive: controller.isLive,
                                 onSelectEpisode: { switchTo($0) },
                                 onRate: { setRate($0) },
                                 onClose: { showFullscreen = false })
        }
        .task { await resolve() }
        .onAppear {
            controller.update(preference: PlayerKernelPreference.from(library.settings.playerKernel), rate: rate)
            controller.onEnded = { playNext(auto: true) }
            prepareVolumeSlider()
        }
        .onChange(of: library.settings.playerKernel) { _, newValue in
            controller.update(preference: PlayerKernelPreference.from(newValue), rate: rate)
        }
        .onDisappear {
            saveProgress(force: true)
            controller.stop()
        }
        .onReceive(ticker) { _ in tick() }
    }

    // MARK: - 手势

    /// 关闭播放页（按钮和手势都走这里）
    private func close() {
        saveProgress(force: true)
        controller.stop()
        dismiss()
    }

    /// 左边缘往右滑：起手点必须在屏幕最左边 32pt 内，横向位移为主
    private var backSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard value.startLocation.x < 32 else {
                    dragX = 0
                    return
                }
                let dx = value.translation.width
                let dy = value.translation.height
                dragX = (dx > 0 && abs(dx) > abs(dy)) ? dx : 0
            }
            .onEnded { value in
                guard value.startLocation.x < 32 else { return }
                if value.translation.width > 70 || value.predictedEndTranslation.width > 180 {
                    close()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { dragX = 0 }
                }
            }
    }

    /// 画面上的拖拽：先判方向 —— 竖直向下=关闭播放页；其余交给亮度/音量/快进
    private var videoDragGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                let horizontal = abs(dx) > abs(dy)
                if horizontal {
                    dragY = 0
                    let seconds = Double(dx) / 6.0            // 每 6pt ≈ 1 秒，手指滑一屏 ≈ 90 秒
                    hud = GestureHUD(kind: .seek, value: seconds,
                                     text: "\(seconds >= 0 ? "+" : "")\(Int(seconds)) 秒")
                    controller.seek(to: max(0, min(controller.duration > 0 ? controller.duration - 1
                                                                          : controller.position + seconds,
                                                  controller.position + seconds)))
                    return
                }
                if dy > 0 && abs(dy) > abs(dx) * 1.2 {
                    dragY = dy                                     // 下滑关闭
                    hud = nil
                    return
                }
                dragY = 0
                // 左半边调亮度、右半边调音量（和主流播放器一致）
                let delta = -Double(dy) / 260.0
                if value.startLocation.x < UIScreen.main.bounds.width / 2 {
                    brightness = min(1, max(0, brightness + CGFloat(delta)))
                    UIScreen.main.brightness = brightness
                    hud = GestureHUD(kind: .brightness, value: Double(brightness),
                                     text: "\(Int(brightness * 100))%")
                } else {
                    volume = min(1, max(0, volume + Float(delta)))
                    volumeSlider?.value = volume
                    hud = GestureHUD(kind: .volume, value: Double(volume),
                                     text: "\(Int(volume * 100))%")
                }
            }
            .onEnded { value in
                let dy = value.translation.height
                if dy > 110 || value.predictedEndTranslation.height > 240 {
                    hud = nil
                    close()
                    return
                }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { dragY = 0 }
                clearHUDSoon()
            }
    }

    private func clearHUDSoon() {
        guard hud != nil else { return }
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            hud = nil
        }
    }

    /// iOS 没有公开的"设置系统音量"API，业界做法是拿 MPVolumeView 里那个 UISlider 来用
    private func prepareVolumeSlider() {
        let volumeView = MPVolumeView(frame: .zero)
        volumeSlider = volumeView.subviews.compactMap { $0 as? UISlider }.first
        volume = volumeSlider?.value ?? AVAudioSession.sharedInstance().outputVolume
        brightness = UIScreen.main.brightness
    }

    // MARK: - 视频区

    private var videoArea: some View {
        ZStack {
            Color.black
            // 同一时刻只允许一个播放画面存在：全屏时这里留黑底
            if showFullscreen {
                Button {
                    showFullscreen = false
                } label: {
                    Label("回到小窗", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
            } else if controller.active == .system {
                VideoPlayer(player: controller.av.player)
            } else {
                MPVVideoView(engine: controller.mpv)
            }

            if danmakuEnabled, !danmaku.isEmpty {
                DanmakuOverlay(comments: danmaku,
                               position: { extrapolatedPosition },
                               isPlaying: { controller.isPlaying })
                    .padding(.horizontal, 2)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            if let hud {
                GestureHUDView(hud: hud)
            }
            if controller.buffering {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.3)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(videoDragGesture)
        .onLongPressGesture(minimumDuration: 0.5) {
            // 长按临时 2 倍速（松手恢复）
        } onPressingChanged: { pressing in
            guard controller.videoAspectReady else { return }
            if pressing, !longPressRate {
                longPressRate = true
                controller.setRate(2.0)
                hud = GestureHUD(kind: .rate, value: 2.0, text: "2 倍速播放中")
            } else if !pressing, longPressRate {
                longPressRate = false
                controller.setRate(rate)
                clearHUDSoon()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !showFullscreen, controller.videoAspectReady {
                Button {
                    showFullscreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.footnote)
                        .padding(8)
                        .background(.black.opacity(0.45), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(8)
            }
        }
    }

    // MARK: - 信息

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(episode?.name ?? item.name).font(.headline).lineLimit(2)
            Text(item.name).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if resolving {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在取播放地址…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let errorText {
                VStack(alignment: .leading, spacing: 6) {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                    // 系统内核失败时给一条"换 mpv 再试"的直接出路
                    if controller.active == .system, controller.videoAspectReady {
                        Button {
                            controller.switchKernel(to: .mpv)
                        } label: {
                            Label("用 mpv 内核再试一次", systemImage: "arrow.triangle.2.circlepath")
                                .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                    }
                }
            }
            if let note = controller.kernelNote {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            if let lastError = controller.errorText, controller.active == .mpv {
                VStack(alignment: .leading, spacing: 2) {
                    Text("播放器：\(lastError)").font(.caption).foregroundStyle(.orange)
                    Text("当前用的是 mpv 内核；如果还是不行，多半是源给的地址本身有问题")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if let hint = controller.av.formatHint, !controller.videoAspectReady {
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
            Text("当前内核：\(controller.active.label)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 进度

    private var progressRow: some View {
        VStack(spacing: 2) {
            if controller.isLive {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("直播中").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                Slider(value: Binding(get: { controller.position },
                                      set: { controller.seek(to: $0) }),
                       in: 0...max(1, controller.duration))
                HStack {
                    Text(Self.timeText(controller.position)).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(Self.timeText(controller.duration)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 控制条

    private var controlBar: some View {
        HStack(spacing: Theme.spacingM) {
            Button { switchTo(index - 1) } label: {
                Image(systemName: "backward.end.fill").font(.title3).frame(width: 44, height: 44)
            }
            .disabled(index <= 0)

            Button { controller.toggle() } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 52, height: 44)
            }

            Button { playNext(auto: false) } label: {
                Image(systemName: "forward.end.fill").font(.title3).frame(width: 44, height: 44)
            }
            .disabled(index >= episodes.count - 1)

            Button { seek(by: -15) } label: {
                Image(systemName: "gobackward.15").font(.title3).frame(width: 44, height: 44)
            }
            Button { seek(by: 15) } label: {
                Image(systemName: "goforward.15").font(.title3).frame(width: 44, height: 44)
            }

            Spacer()

            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                    Button {
                        setRate(value)
                    } label: {
                        Text(value == 1.0 ? "正常速度" : String(format: "%g 倍", value))
                    }
                }
            } label: {
                Text(rate == 1.0 ? "倍速" : String(format: "%gx", rate))
                    .font(.subheadline)
                    .frame(height: 44)
                    .padding(.horizontal, 4)
            }

            Button {
                danmakuEnabled.toggle()
                library.settings.danmakuEnabled = danmakuEnabled
                if danmakuEnabled, danmaku.isEmpty { Task { await loadDanmaku() } }
            } label: {
                Text(danmakuEnabled ? "弹幕" : "弹")
                    .font(.subheadline)
                    .fontWeight(danmakuEnabled ? .semibold : .regular)
                    .frame(minWidth: 44, height: 44)
            }

            Button { showFullscreen = true } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .disabled(!controller.videoAspectReady)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
    }

    // MARK: - 选集条

    private var episodeStrip: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            Text("选集（\(episodes.count)）· \(request.flag)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                ScrollViewReader { proxy in
                    HStack(spacing: Theme.spacingM) {
                        ForEach(Array(episodes.enumerated()), id: \.element.id) { i, ep in
                            Button { switchTo(i) } label: {
                                EpisodeChip(text: ep.name, selected: i == index)
                            }
                            .buttonStyle(.plain)
                            .id(i)
                        }
                    }
                    .padding(.vertical, 2)
                    // 进来时把"正在播的那一集"滚到中间，不用自己找
                    .onAppear { proxy.scrollTo(index, anchor: .center) }
                    .onChange(of: index) { _, newValue in
                        withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                    }
                }
            }
        }
    }

    // MARK: - 逻辑

    private func setRate(_ value: Double) {
        rate = value
        controller.setRate(value)
        library.settings.rate = value
    }

    private func switchTo(_ newIndex: Int) {
        guard newIndex >= 0, newIndex < episodes.count, newIndex != index else { return }
        saveProgress(force: true)
        index = newIndex
        Task { await resolve() }
    }

    private func playNext(auto: Bool) {
        guard index + 1 < episodes.count else {
            if auto { controller.pause() }
            return
        }
        // 自动下一集只认"真的看到结尾"（时长合理且进度接近末尾），
        // 避免播放失败/秒退时连环跳集 —— 手动点下一集不受此限制
        if auto {
            let position = controller.position
            let duration = controller.duration
            guard duration > 30, position > duration * 0.9 else {
                CatyLog.shared.info("player", "忽略自动下一集（duration=\(Int(duration))s position=\(Int(position))s）")
                return
            }
        }
        switchTo(index + 1)
    }

    private func seek(by seconds: Double) {
        let current = controller.position
        let total = controller.duration
        let target = max(0, min(total > 0 ? total - 1 : current + seconds, current + seconds))
        controller.seek(to: target)
        hud = GestureHUD(kind: .seek, value: seconds, text: "\(seconds >= 0 ? "+" : "")\(Int(seconds)) 秒")
        clearHUDSoon()
    }

    @MainActor
    private func resolve() async {
        guard let client else {
            resolving = false
            errorText = "运行时还没就绪"
            return
        }
        guard let episode else {
            resolving = false
            errorText = "没有可播的剧集"
            return
        }
        resolving = true
        errorText = nil
        defer { resolving = false }

        do {
            let (url, headers) = try await client.resolvePlay(episodeURL: episode.url,
                                                             flag: request.flag,
                                                             site: request.site)
            controller.update(preference: PlayerKernelPreference.from(library.settings.playerKernel), rate: rate)
            controller.load(url: url, headers: headers, title: episode.name)
            // 源会问"现在播什么"来配弹幕；把上下文给它
            PlaybackContext.shared.update(title: item.name,
                                          episodeName: episode.name,
                                          flag: request.flag,
                                          fileName: episode.url)
            danmaku = []
            if danmakuEnabled { Task { await loadDanmaku() } }

            // 断点续播：同一集的进度超过 10 秒才跳（等播放器准备好再 seek）
            if library.settings.rememberProgress,
               let record = library.history(for: item),
               record.episodeIndex == index,
               record.positionSec > 10 {
                let target = record.positionSec
                Task {
                    for _ in 0..<25 {
                        if controller.duration > 0 { break }
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    controller.seek(to: target)
                    CatyLog.shared.info("player", "断点续播：从 \(Int(target))s 继续")
                }
            }
        } catch {
            errorText = "取播放地址失败：\(error.localizedDescription)"
            CatyLog.shared.warn("player", "取播放地址失败：\(error.localizedDescription)")
        }
    }

    private func tick() {
        guard !resolving else { return }
        saveProgress(force: false)
    }

    /// 播放位置外推：采样是 0.35s 一次，弹幕要按帧动，所以"位置 + 这之后过去的时间×倍速"
    private var extrapolatedPosition: Double {
        guard controller.isPlaying else { return controller.position }
        return controller.position + Date().timeIntervalSince(controller.positionUpdatedAt) * rate
    }

    /// 取这一集的弹幕（源的 /danmu/auto：<剧名> + <第几集>）
    private func loadDanmaku() async {
        // 弹幕接口在**这个站点所属的那个源**上（多源同进程时必须用对地址）
        guard let client, let base = client.base(for: request.site.sourceId) else { return }
        let comments = await DanmakuService.comments(base: base,
                                                     name: item.name,
                                                     episode: index + 1)
        danmaku = comments
    }

    private func saveProgress(force: Bool) {
        guard library.settings.rememberProgress, let episode else { return }
        guard controller.duration > 0 || force else { return }
        library.updateHistory(item: item,
                              episodeIndex: index,
                              episodeName: episode.name,
                              position: controller.position,
                              duration: controller.duration,
                              forceWrite: force)
    }

    private static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - 手势提示（亮度/音量/快进）

struct GestureHUD: Equatable {
    enum Kind { case brightness, volume, seek, rate }
    let kind: Kind
    let value: Double
    let text: String
}

struct GestureHUDView: View {

    let hud: GestureHUD

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
            Text(hud.text).font(.subheadline).monospacedDigit()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
        .transition(.opacity)
    }

    private var icon: String {
        switch hud.kind {
        case .brightness:
            return hud.value > 0.5 ? "sun.max.fill" : "sun.min.fill"
        case .volume:
            if hud.value <= 0.01 { return "speaker.slash.fill" }
            return hud.value > 0.5 ? "speaker.wave.3.fill" : "speaker.wave.1.fill"
        case .seek:
            return hud.value >= 0 ? "goforward" : "gobackward"
        case .rate:
            return "forward.fill"
        }
    }
}

/// 选集按钮：比分类那排胶囊**大一圈**（用户反馈原来的太小、不好点）
/// 44pt 是 iOS 的最小舒适点击区，这里按 44 高 + 至少 60 宽来做。
private struct EpisodeChip: View {

    let text: String
    let selected: Bool

    var body: some View {
        Text(text)
            .font(.subheadline)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minWidth: 60, minHeight: 44)
            .background(selected ? Theme.accent.opacity(0.22) : Color.secondary.opacity(0.12))
            .foregroundStyle(selected ? Theme.accent : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}
