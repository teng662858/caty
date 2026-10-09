//
//  FullscreenPlayerView.swift
//  全屏播放（2026-10-10 用户："播放页没什么功能，全屏播放都没有"）
//
//  做法：
//   · 用 fullScreenCover 弹出，进来时把界面切成**横屏**，退出时切回竖屏
//     （平时 App 锁竖屏，见 ScreenOrientation / CatyAppDelegate）
//   · 视频铺满整屏，点一下显示/隐藏控制层（4 秒无操作自动隐藏）
//   · 控制层：进度条（可拖）/ 时间 / 播放暂停 / ±15 秒 / 倍速 / 选集 / 退出全屏
//   · 复用同一个 AVPlayerEngine —— 原来那个（非全屏的）播放器在弹出期间会被替换成黑底，
//     保证同一时刻只有一个 VideoPlayer，不会出现两个画面抢渲染
//

import SwiftUI
import AVKit

struct FullscreenPlayerView: View {

    @ObservedObject var controller: PlaybackController
    @ObservedObject private var library = LibraryStore.shared
    /// 弹幕：和小窗共享同一份（源推来的也会即时出现）
    @ObservedObject private var danmakuStore = DanmakuStore.shared
    let episodes: [Episode]
    let currentIndex: Int
    let rate: Double
    let isLive: Bool
    let onSelectEpisode: (Int) -> Void
    let onRate: (Double) -> Void
    let onClose: () -> Void
    /// 上一集 / 下一集
    let onPrev: (() -> Void)?
    let onNext: (() -> Void)?
    /// 弹幕开关（跟随播放页的设置）
    @Binding var danmakuEnabled: Bool
    let danmakuCount: Int

    @State private var controlsVisible = true
    @State private var scrubbing = false
    @State private var hideTask: Task<Void, Never>?
    /// 手势状态（本地一份，和小窗各自独立）
    @State private var hud: GestureHUD?
    @State private var volume: Float = 0.5
    @State private var brightness: CGFloat = UIScreen.main.brightness
    @State private var volumeSlider: UISlider?
    @State private var hideHUDTask: Task<Void, Never>?
    /// 竖屏视频（短剧）：不强行横屏，否则画面只占中间一小条
    @State private var forcedLandscape = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if controller.active == .system {
                    VideoPlayer(player: controller.av.player)
                } else {
                    MPVVideoView(engine: controller.mpv)
                }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { toggleControls() }
            .gesture(videoDragGesture)
            .onLongPressGesture(minimumDuration: 0.5) {
            } onPressingChanged: { pressing in
                if pressing {
                    controller.setRate(2.0)
                    hud = GestureHUD(kind: .rate, value: 2.0, text: "2 倍速播放中")
                } else {
                    controller.setRate(rate)
                    clearHUDSoon()
                }
            }

            if danmakuEnabled, let comments = danmakuStore.current {
                DanmakuOverlay(comments: comments,
                               position: { extrapolatedPosition },
                               isPlaying: { controller.isPlaying },
                               fontSize: CGFloat(library.settings.danmakuFontSize),
                               opacity: library.settings.danmakuOpacity,
                               laneSpacing: CGFloat(library.settings.danmakuLaneSpacing),
                               showTop: library.settings.danmakuShowTop,
                               showBottom: library.settings.danmakuShowBottom,
                               blockWords: library.settings.danmakuBlockWords
                                   .split(separator: ",").map(String.init))
                    .ignoresSafeArea()
            }

            if let hud {
                GestureHUDView(hud: hud)
            }

            if controlsVisible {
                controls
                    .transition(.opacity)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            prepareVolumeSlider()
            applyOrientation()
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            ScreenOrientation.lockPortrait()
        }
    }

    // MARK: - 控制层

    private var controls: some View {
        VStack {
            topBar
            Spacer()
            bottomBar
        }
        .padding(Theme.padding)
    }

    private var topBar: some View {
        HStack(spacing: Theme.spacingM) {
            Button {
                close()
            } label: {
                Label("退出全屏", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)

            Text(controller.currentTitle ?? "")
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer()

            Button {
                forcedLandscape.toggle()
                if forcedLandscape { ScreenOrientation.lockLandscape() } else { ScreenOrientation.lockPortrait() }
                interactive()
            } label: {
                Image(systemName: "rotate.right")
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)

            Button {
                danmakuEnabled.toggle()
                interactive()
            } label: {
                Text(danmakuEnabled ? "弹幕开" : "弹幕")
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)

            if episodes.count > 1 {
                Menu {
                    ForEach(Array(episodes.enumerated()), id: \.element.id) { i, ep in
                        Button {
                            onSelectEpisode(i)
                            interactive()
                        } label: {
                            if i == currentIndex {
                                Label(ep.name, systemImage: "checkmark")
                            } else {
                                Text(ep.name)
                            }
                        }
                    }
                } label: {
                    Label("选集", systemImage: "list.bullet")
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
        }
        .padding(.top, 6)
    }

    private var bottomBar: some View {
        VStack(spacing: Theme.spacingS) {
            if isLive {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("直播中").font(.caption).foregroundStyle(.white)
                    Spacer()
                }
            } else {
                HStack(spacing: 10) {
                    Text(Self.timeText(controller.position)).font(.caption2).monospacedDigit()
                    Slider(value: Binding(get: { controller.position },
                                          set: {
                                              scrubbing = true
                                              controller.seek(to: $0)
                                          }), in: 0...max(1, controller.duration))
                    .tint(.white)
                    Text(Self.timeText(controller.duration)).font(.caption2).monospacedDigit()
                }
            }

            HStack(spacing: Theme.spacingL) {
                if let onPrev {
                    Button { onPrev(); interactive() } label: {
                        Image(systemName: "backward.end.fill").font(.title3).frame(width: 44, height: 44)
                    }
                }
                Button { step(-15) } label: {
                    Image(systemName: "gobackward.15").font(.title2).frame(width: 44, height: 44)
                }
                Button { controller.toggle(); interactive() } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.largeTitle)
                        .frame(width: 60, height: 44)
                }
                Button { step(15) } label: {
                    Image(systemName: "goforward.15").font(.title2).frame(width: 44, height: 44)
                }
                if let onNext {
                    Button { onNext(); interactive() } label: {
                        Image(systemName: "forward.end.fill").font(.title3).frame(width: 44, height: 44)
                    }
                }

                Spacer()

                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                        Button {
                            onRate(value)
                            interactive()
                        } label: {
                            Text(value == 1.0 ? "正常速度" : String(format: "%g 倍", value))
                        }
                    }
                } label: {
                    Text(rate == 1.0 ? "倍速" : String(format: "%gx", rate))
                        .font(.subheadline)
                        .frame(height: 44)
                        .padding(.horizontal, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }
        .padding(.bottom, 10)
    }

    // MARK: - 逻辑

    /// 全屏里的手势：左半边上下=亮度、右半边上下=音量、横向=快进、长按=2 倍速
    private var videoDragGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) > abs(dy) {
                    let seconds = Double(dx) / 6.0
                    let current = controller.position
                    let total = controller.duration
                    let target = max(0, min(total > 0 ? total - 1 : current + seconds, current + seconds))
                    controller.seek(to: target)
                    hud = GestureHUD(kind: .seek, value: seconds,
                                     text: (seconds >= 0 ? "+" : "") + String(Int(seconds)) + " 秒")
                    return
                }
                let delta = -Double(dy) / 260.0
                if value.startLocation.x < UIScreen.main.bounds.width / 2 {
                    brightness = min(1, max(0, brightness + CGFloat(delta)))
                    UIScreen.main.brightness = brightness
                    hud = GestureHUD(kind: .brightness, value: Double(brightness),
                                     text: String(Int(brightness * 100)) + "%")
                } else {
                    volume = min(1, max(0, volume + Float(delta)))
                    volumeSlider?.value = volume
                    hud = GestureHUD(kind: .volume, value: Double(volume),
                                     text: String(Int(volume * 100)) + "%")
                }
            }
            .onEnded { _ in
                clearHUDSoon()
            }
    }

    private func prepareVolumeSlider() {
        let volumeView = MPVolumeView(frame: .zero)
        volumeSlider = volumeView.subviews.compactMap { $0 as? UISlider }.first
        volume = volumeSlider?.value ?? AVAudioSession.sharedInstance().outputVolume
        brightness = UIScreen.main.brightness
    }

    private func clearHUDSoon() {
        guard hud != nil else { return }
        hideHUDTask?.cancel()
        hideHUDTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            hud = nil
        }
    }

    private func close() {
        onClose()
    }

    /// 横屏还是竖屏：看视频自己的宽高比（竖屏短剧硬转横屏会变成中间一小条）
    private func applyOrientation() {
        if forcedLandscape {
            ScreenOrientation.lockLandscape()
            return
        }
        if controller.isPortraitVideo {
            ScreenOrientation.lockPortrait()
        } else {
            ScreenOrientation.lockLandscape()
        }
    }

    private var extrapolatedPosition: Double {
        guard controller.isPlaying else { return controller.position }
        return controller.position + Date().timeIntervalSince(controller.positionUpdatedAt) * rate
    }


    private func step(_ seconds: Double) {
        let total = controller.duration
        let current = controller.position
        let target = max(0, min(total > 0 ? total - 1 : current + seconds, current + seconds))
        controller.seek(to: target)
        interactive()
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() } else { hideTask?.cancel() }
    }

    /// 用户主动操作过 → 重新计时自动隐藏
    private func interactive() {
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { controlsVisible = false }
        }
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
