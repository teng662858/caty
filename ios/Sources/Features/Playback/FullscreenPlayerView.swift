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

    @ObservedObject var engine: AVPlayerEngine
    let episodes: [Episode]
    let currentIndex: Int
    let rate: Double
    let onSelectEpisode: (Int) -> Void
    let onRate: (Double) -> Void
    let onClose: () -> Void

    @State private var controlsVisible = true
    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var scrubbing = false
    @State private var hideTask: Task<Void, Never>?

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: engine.player)
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }

            if controlsVisible {
                controls
                    .transition(.opacity)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            ScreenOrientation.lockLandscape()
            syncFromEngine()
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            ScreenOrientation.lockPortrait()
        }
        .onReceive(ticker) { _ in tick() }
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

            Text(engine.currentTitle ?? "")
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer()

            if episodes.count > 1 {
                Menu {
                    ForEach(Array(episodes.enumerated()), id: \.element.id) { i, ep in
                        Button {
                            onSelectEpisode(i)
                            syncFromEngine()
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
            HStack(spacing: 10) {
                Text(Self.timeText(position)).font(.caption2).monospacedDigit()
                Slider(value: Binding(get: { position },
                                      set: {
                                          position = $0
                                          scrubbing = true
                                      }), in: 0...max(1, duration)) { editing in
                    if !editing {
                        scrubbing = false
                        engine.seek(to: position)
                    }
                }
                .tint(.white)
                Text(Self.timeText(duration)).font(.caption2).monospacedDigit()
            }

            HStack(spacing: Theme.spacingL) {
                Button { step(-15) } label: {
                    Image(systemName: "gobackward.15").font(.title2).frame(width: 44, height: 44)
                }
                Button { engine.toggle(); interactive() } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.largeTitle)
                        .frame(width: 60, height: 44)
                }
                Button { step(15) } label: {
                    Image(systemName: "goforward.15").font(.title2).frame(width: 44, height: 44)
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

    private func close() {
        onClose()
    }

    private func step(_ seconds: Double) {
        let target = max(0, min(duration > 0 ? duration - 1 : position + seconds, position + seconds))
        position = target
        engine.seek(to: target)
        interactive()
    }

    private func tick() {
        guard !scrubbing else { return }
        let current = engine.player.currentTime().seconds
        if current.isFinite, current >= 0 { position = current }
        if let total = engine.player.currentItem?.duration.seconds, total.isFinite, total > 0 {
            duration = total
        }
    }

    private func syncFromEngine() {
        let current = engine.player.currentTime().seconds
        if current.isFinite, current >= 0 { position = current }
        if let total = engine.player.currentItem?.duration.seconds, total.isFinite, total > 0 {
            duration = total
        }
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
