//
//  FullscreenPlayerView.swift
//  全屏播放（P6+ 重写）：横屏铺满 + 我们自己的控制层（和小窗共用 PlayerControlsOverlay）
//
//  这次重写的起点：之前把太多东西塞进一个表达式，swift-frontend 在 CI 上直接崩了。
//  现在拆成 —— 画面层 / 弹幕层 / 控制层 / 手势 四块，每块都很小。
//
//  方向策略：进全屏时按**视频自己的宽高比**决定方向（竖屏短剧不硬转横屏），顶栏"旋转"可手动切。
//

import SwiftUI
import AVKit
import MediaPlayer

struct FullscreenPlayerView: View {

    @ObservedObject var controller: PlaybackController
    @ObservedObject private var library = LibraryStore.shared

    let episodes: [Episode]
    let currentIndex: Int
    let rate: Double
    let isLive: Bool
    let onSelectEpisode: (Int) -> Void
    let onRate: (Double) -> Void
    let onClose: () -> Void
    let onPrev: () -> Void
    let canGoPrev: Bool
    let onNext: () -> Void
    let canGoNext: Bool
    let danmakuEnabled: Bool
    let onToggleDanmaku: () -> Void

    @State private var danmaku: [DanmakuComment] = []
    @State private var hud: GestureHUD?
    @State private var volume: Float = 0.5
    @State private var brightness: CGFloat = UIScreen.main.brightness
    @State private var volumeSlider: UISlider?
    @State private var hideHUDTask: Task<Void, Never>?
    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var forcedLandscape = false
    @State private var locked = false
    @State private var toast: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            videoLayer
            danmakuLayer
            if let hud { GestureHUDView(hud: hud) }
            if let toast { toastView(toast) }
            if controlsVisible { controls }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear(perform: onAppearAction)
        .onDisappear(perform: onDisappearAction)
        .onReceive(DanmakuStore.shared.$comments) { list in
            danmaku = list
        }
    }

    // MARK: - 画面

    private var videoLayer: some View {
        Group {
            if controller.active == .system {
                PlayerHostView(player: controller.av.player,
                               fill: controller.aspectMode.fills,
                               pip: controller.pip)
            } else {
                MPVVideoView(engine: controller.mpv)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        .gesture(videoDragGesture)
        .onLongPressGesture(minimumDuration: 0.5) {
            guard !locked, controller.videoAspectReady else { return }
            controller.setRate(2.0)
            hud = GestureHUD(kind: .rate, value: 2.0, text: "2 倍速播放中")
        } onPressingChanged: { pressing in
            guard !pressing, !locked else { return }
            controller.setRate(rate)
            clearHUDSoon()
        }
    }

    // MARK: - 弹幕

    @ViewBuilder
    private var danmakuLayer: some View {
        if danmakuEnabled, !danmaku.isEmpty {
            DanmakuOverlay(comments: danmaku,
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
    }

    // MARK: - 控制层

    private var controls: some View {
        PlayerControlsOverlay(state: chromeState, actions: chromeActions)
            .transition(.opacity)
    }

    private var chromeState: PlayerChromeState {
        var state = PlayerChromeState()
        state.isFullscreen = true
        state.title = controller.currentTitle ?? ""
        state.subtitle = subtitleText
        state.position = controller.position
        state.duration = controller.duration
        state.isLive = isLive
        state.isPlaying = controller.isPlaying
        state.rate = rate
        state.danmakuEnabled = danmakuEnabled
        state.danmakuCount = danmaku.count
        state.infoLine = infoLine
        state.aspectLabel = controller.aspectMode.label
        state.introSeconds = library.settings.skipIntroSeconds
        state.locked = locked
        return state
    }

    private var chromeActions: PlayerChromeActions {
        var actions = PlayerChromeActions()
        actions.close = onClose
        actions.togglePlay = { controller.toggle(); interactive() }
        actions.seek = { controller.seek(to: $0); interactive() }
        actions.seekBy = { step($0) }
        actions.previousEpisode = onPrev
        actions.nextEpisode = onNext
        actions.setRate = { onRate($0); interactive() }
        actions.toggleDanmaku = { onToggleDanmaku(); interactive() }
        actions.selectEpisode = { selectEpisode(); interactive() }
        actions.rotate = { rotate() }
        actions.cycleAspect = { controller.cycleAspect(); showToast("画面比例：" + controller.aspectMode.label) }
        actions.pictureInPicture = { startPiP() }
        actions.screenshot = { takeScreenshot() }
        actions.skipIntro = { skipIntro() }
        actions.setLocked = { value in
            locked = value
            if value { showToast("已锁定：点左侧锁头解锁") }
        }
        return actions
    }

    private var subtitleText: String {
        guard currentIndex >= 0, currentIndex < episodes.count else { return "" }
        return "第 " + String(currentIndex + 1) + " 集 · " + episodes[currentIndex].name
    }

    /// 信息行：分辨率 · 帧率 · 下载速度（拿得到才显示）
    private var infoLine: String {
        var parts: [String] = []
        if let size = controller.videoSizeText { parts.append(size) }
        if let fps = controller.frameRateText { parts.append(fps) }
        if let speed = controller.speedText { parts.append(speed) }
        return parts.joined(separator: "  ")
    }

    // MARK: - 手势

    private var videoDragGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard !locked else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) > abs(dy) {
                    let seconds = Double(dx) / 6.0
                    let current = controller.position
                    let total = controller.duration
                    let target = max(0, min(total > 0 ? total - 1 : current + seconds, current + seconds))
                    controller.seek(to: target)
                    hud = GestureHUD(kind: .seek, value: seconds, text: seekText(seconds))
                    return
                }
                let delta = -Double(dy) / 260.0
                if value.startLocation.x < UIScreen.main.bounds.width / 2 {
                    brightness = clampUnit(brightness + CGFloat(delta))
                    UIScreen.main.brightness = brightness
                    hud = GestureHUD(kind: .brightness, value: Double(brightness), text: percentText(brightness))
                } else {
                    volume = clampVolume(volume + Float(delta))
                    volumeSlider?.value = volume
                    hud = GestureHUD(kind: .volume, value: Double(volume), text: percentText(CGFloat(volume)))
                }
            }
            .onEnded { _ in
                clearHUDSoon()
            }
    }

    // MARK: - 动作

    private func onAppearAction() {
        prepareVolumeSlider()
        applyOrientation()
        scheduleHideControls()
    }

    private func onDisappearAction() {
        hideControlsTask?.cancel()
        ScreenOrientation.lockPortrait()
    }

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

    private func rotate() {
        forcedLandscape.toggle()
        applyOrientation()
        showToast(forcedLandscape ? "横屏" : "竖屏")
    }

    private func selectEpisode() {
        guard !episodes.isEmpty else { return }
        let sheet = UIAlertController(title: "选集", message: nil, preferredStyle: .actionSheet)
        for (i, episode) in episodes.enumerated() {
            let title = i == currentIndex ? "✓ " + episode.name : episode.name
            sheet.addAction(UIAlertAction(title: title, style: .default) { _ in
                onSelectEpisode(i)
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = UIApplication.shared.windows.first
        }
        UIApplication.shared.catyTopViewController()?.present(sheet, animated: true)
    }

    private func step(_ seconds: Double) {
        let total = controller.duration
        let current = controller.position
        let target = max(0, min(total > 0 ? total - 1 : current + seconds, current + seconds))
        controller.seek(to: target)
        hud = GestureHUD(kind: .seek, value: seconds, text: seekText(seconds))
        interactive()
    }

    private func skipIntro() {
        let seconds = max(1, library.settings.skipIntroSeconds)
        let base = controller.position
        let limit = controller.duration > 0 ? controller.duration - 1 : base + Double(seconds)
        controller.seek(to: min(limit, base + Double(seconds)))
        showToast("已跳片头 " + String(seconds) + " 秒")
    }

    private func startPiP() {
        guard controller.active == .system else {
            showToast("画中画只支持系统内核（设置里可切）")
            return
        }
        controller.pip.start()
    }

    private func takeScreenshot() {
        Task {
            let message = await controller.screenshot()
            showToast(message)
        }
    }

    // MARK: - 控制层显隐 / 提示

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHideControls() } else { hideControlsTask?.cancel() }
    }

    private func interactive() {
        scheduleHideControls()
    }

    private func scheduleHideControls() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { controlsVisible = false }
        }
    }

    private func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if toast == text { toast = nil }
        }
    }

    private func toastView(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.white)
                .padding(.bottom, 120)
            Spacer()
        }
    }

    // MARK: - 小工具

    private var extrapolatedPosition: Double {
        guard controller.isPlaying else { return controller.position }
        return controller.position + Date().timeIntervalSince(controller.positionUpdatedAt) * rate
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

    private func seekText(_ seconds: Double) -> String {
        let sign = seconds >= 0 ? "+" : ""
        return sign + String(Int(seconds)) + " 秒"
    }

    private func percentText(_ value: CGFloat) -> String {
        String(Int(value * 100)) + "%"
    }

    private func clampUnit(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }

    private func clampVolume(_ value: Float) -> Float {
        min(1, max(0, value))
    }
}

extension UIApplication {

    /// 找最上层控制器（弹系统的"选集"菜单要用）
    func catyTopViewController(base: UIViewController? = nil) -> UIViewController? {
        let root = base ?? connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?
            .rootViewController
        if let presented = root?.presentedViewController {
            return catyTopViewController(base: presented)
        }
        if let navigation = root as? UINavigationController {
            return catyTopViewController(base: navigation.visibleViewController)
        }
        if let tab = root as? UITabBarController {
            return catyTopViewController(base: tab.selectedViewController)
        }
        return root
    }
}
