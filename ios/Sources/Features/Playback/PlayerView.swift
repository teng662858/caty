//
//  PlayerView.swift
//  播放页 · 小窗（竖屏）—— 2026-10-11 重做成"画面优先"
//
//  旧版的问题（用户原话"为什么播放器还是这样的"）：
//  画面只占最上面一小条，下面一大片空白，控制按钮挤在滚动区里、还没有进度条。
//  第五轮的"播放页重做"当时只接到了**全屏**（FullscreenPlayerView）那一侧。
//
//  现在：
//   ① 画面区：按视频自己的宽高比居中（高度不低于 230pt、不高于屏幕的 58%），
//      弹幕 + 控制层都压在画面里；控制层和全屏**共用 PlayerControlsOverlay**（compact 模式）。
//   ② 画面下方：剧名/集/线路/内核 + 截图 · 画中画 + 选集（点画面之外的地方看的都是这些）。
//
//  小窗的控制层**常显**（全屏才走"点一下显隐 + 4.5 秒自动隐藏"）：小窗是边看边挑的场景，
//  进度条和选集要随点随有。
//
//  手势（都在画面上，锁定后全部失效；返回手势一直在）：
//    左侧上下 = 亮度、右侧上下 = 音量、左右横滑 = 快进/快退、长按 0.5s = 2 倍速、下滑 = 关播放页；
//    屏幕左边缘往右滑 = 返回（全屏弹出没有系统返回手势）。
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
    /// 跟手位移：下滑关闭 / 左边缘返回各一个（拖的时候页面跟着动）
    @State private var dragY: CGFloat = 0
    @State private var dragX: CGFloat = 0
    /// 全屏（横屏）播放
    @State private var showFullscreen = false
    /// 手势 HUD（亮度/音量/快进提示）
    @State private var hud: GestureHUD?
    /// 一句话提示（截图结果 / 画面比例 / 锁定状态）
    @State private var toast: String?
    @State private var volume: Float = 0.5
    @State private var brightness: CGFloat = UIScreen.main.brightness
    @State private var volumeSlider: UISlider?
    @State private var hideHUDTask: Task<Void, Never>?
    /// 长按倍速（只在真的按满 0.5 秒后生效，见 videoArea 里的注释）
    @State private var longPressRate = false
    /// 锁定：控制层只剩解锁键，画面上的手势全部失效（防误触）
    @State private var locked = false
    /// 弹幕：小窗、全屏、源推送都写同一份 DanmakuStore，这里订阅它的变化
    @State private var danmaku: [DanmakuComment] = []
    @State private var danmakuEnabled: Bool
    /// 取播放地址：连点"下一集"会并发好几个请求，只认最后点的那次
    @State private var resolveTask: Task<Void, Never>?
    @State private var resolveToken = 0

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var item: VodItem { request.item }
    private var episodes: [Episode] { request.episodes }
    private var episode: Episode? {
        guard index >= 0, index < episodes.count else { return nil }
        return episodes[index]
    }
    /// 这一集的唯一键（切集后旧弹幕不能盖到新集上）
    private var episodeKey: String { item.id + "#" + String(index) }

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
                        episodeStrip
                    }
                    .padding(Theme.padding)
                }
            }
            // 控制层自带返回键，系统导航栏让位（不然顶部会挤两条）
            .toolbar(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
        }
        .offset(y: max(0, dragY))
        .offset(x: max(0, dragX))
        .simultaneousGesture(backSwipeGesture)
        .fullScreenCover(isPresented: $showFullscreen) { fullscreenCover }
        .task { startResolve() }
        .onAppear(perform: onAppearAction)
        .onChange(of: library.settings.playerKernel) { _, newValue in
            controller.update(preference: PlayerKernelPreference.from(newValue), rate: rate)
        }
        .onDisappear(perform: onDisappearAction)
        .onReceive(ticker) { _ in tick() }
        .onReceive(DanmakuStore.shared.$comments) { list in
            danmaku = list
        }
    }

    // MARK: - 画面区

    private var videoArea: some View {
        ZStack {
            Color.black
            pictureLayer
            gestureLayer
            if let hud { GestureHUDView(hud: hud) }
            if let toast { toastBanner(toast) }
            if controller.buffering { bufferingIndicator }
            // 全屏时这里让位（同一时刻只能有一个播放画面，否则两个画面抢同一个 AVPlayer 的渲染层）
            if !showFullscreen {
                PlayerControlsOverlay(state: chromeState, actions: chromeActions)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: videoHeight)
    }

    /// 画面 + 弹幕，按视频自己的宽高比居中（竖屏短剧就竖着，不硬塞 16:9）
    private var pictureLayer: some View {
        ZStack {
            videoSurface
            danmakuLayer
        }
        .aspectRatio(controller.videoAspect ?? 16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var videoSurface: some View {
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
            PlayerHostView(player: controller.av.player,
                           fill: controller.aspectMode.fills,
                           pip: controller.pip)
        } else {
            MPVVideoView(engine: controller.mpv)
        }
    }

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
        }
    }

    /// 手势层：透明、铺满整个画面区，但在控制层**下面**（不然会抢走进度条的拖动）
    private var gestureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(videoDragGesture)
            // ⚠️ 2 倍速只能写在 perform 里：onPressingChanged 是"手指一按下就 true"，
            // 写在它里面会导致**点一下就变 2 倍速**（用户真机反馈过）。
            .onLongPressGesture(minimumDuration: 0.5) {
                guard !locked, controller.videoAspectReady else { return }
                longPressRate = true
                controller.setRate(2.0)
                hud = GestureHUD(kind: .rate, value: 2.0, text: "2 倍速播放中")
            } onPressingChanged: { pressing in
                guard !pressing, longPressRate else { return }
                longPressRate = false
                controller.setRate(rate)
                clearHUDSoon()
            }
    }

    /// 画面区高度：按视频比例算，但不小于 230pt（控制层要放得下）、不超过屏幕的 58%
    private var videoHeight: CGFloat {
        let screen = UIScreen.main.bounds
        let aspect = max(0.4, controller.videoAspect ?? 16.0 / 9.0)
        let natural = screen.width / aspect
        let lower: CGFloat = 230
        let upper = max(lower, min(screen.height * 0.58, 520))
        return min(max(natural, lower), upper)
    }

    private var bufferingIndicator: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .tint(.white)
            .scaleEffect(1.3)
    }

    private func toastBanner(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.white)
                .padding(.bottom, 12)
        }
    }

    // MARK: - 控制层（和全屏同一套）

    private var chromeState: PlayerChromeState {
        var state = PlayerChromeState()
        state.compact = true
        state.title = item.name
        state.subtitle = "第 " + String(index + 1) + " 集 · " + (episode?.name ?? "—")
        state.position = controller.position
        state.duration = controller.duration
        state.isLive = controller.isLive
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
        actions.close = { close() }
        actions.togglePlay = { controller.toggle() }
        actions.seek = { controller.seek(to: $0) }
        actions.seekBy = { seek(by: $0) }
        actions.previousEpisode = { switchTo(index - 1) }
        actions.nextEpisode = { switchTo(index + 1) }
        actions.setRate = { setRate($0) }
        actions.toggleDanmaku = { toggleDanmaku() }
        actions.selectEpisode = { presentEpisodePicker(episodes, currentIndex: index) { switchTo($0) } }
        actions.toggleFullscreen = { showFullscreen = true }
        actions.cycleAspect = {
            controller.cycleAspect()
            showToast("画面比例：" + controller.aspectMode.label)
        }
        actions.pictureInPicture = { startPiP() }
        actions.screenshot = { takeScreenshot() }
        actions.skipIntro = { skipIntro() }
        actions.setLocked = { value in
            locked = value
            if value { showToast("已锁定：点左下角锁头解锁") }
        }
        return actions
    }

    /// 信息行：分辨率 · 帧率 · 下载速度（拿得到才显示）
    private var infoLine: String {
        var parts: [String] = []
        if let size = controller.videoSizeText { parts.append(size) }
        if let fps = controller.frameRateText { parts.append(fps) }
        if let speed = controller.speedText { parts.append(speed) }
        return parts.joined(separator: "  ")
    }

    // MARK: - 画面下方：剧名 / 内核 / 工具 / 选集

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name)
                .font(.headline)
                .lineLimit(2)
            Text((episode?.name ?? "—") + " · " + request.flag + " · 当前内核：" + controller.active.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if resolving {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在取播放地址…").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
            if let note = controller.kernelNote {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            if controller.active == .mpv, let lastError = controller.errorText {
                Text("播放器：\(lastError)").font(.caption).foregroundStyle(.orange)
            }

            utilityRow
        }
    }

    /// 小窗放得下的大按钮：截图 / 画中画（全屏那一排的图标太挤，这里给文字标签）
    private var utilityRow: some View {
        HStack(spacing: Theme.spacingM) {
            Button {
                takeScreenshot()
            } label: {
                Label("截图", systemImage: "camera")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)

            Button {
                startPiP()
            } label: {
                Label("画中画", systemImage: "pip.enter")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)

            if controller.active == .system, errorText != nil {
                Button {
                    controller.switchKernel(to: .mpv)
                } label: {
                    Label("换 mpv 内核再试", systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
            }

            Spacer(minLength: 0)
        }
    }

    private var episodeStrip: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            Text("选集（\(episodes.count)）")
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

    // MARK: - 全屏

    private var fullscreenCover: some View {
        FullscreenPlayerView(controller: controller,
                             episodes: episodes,
                             currentIndex: index,
                             rate: rate,
                             isLive: controller.isLive,
                             onSelectEpisode: { switchTo($0) },
                             onRate: { setRate($0) },
                             onClose: { showFullscreen = false },
                             onPrev: { switchTo(index - 1) },
                             canGoPrev: index > 0,
                             onNext: { switchTo(index + 1) },
                             canGoNext: index < episodes.count - 1,
                             danmakuEnabled: danmakuEnabled,
                             onToggleDanmaku: { toggleDanmaku() })
    }

    // MARK: - 手势

    /// 关闭播放页（返回键、下滑、左边缘右滑都走这里）
    private func close() {
        resolveTask?.cancel()
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

    /// 画面上的拖拽：先判方向 —— 竖直向下 = 关闭播放页；其余交给亮度/音量/快进
    private var videoDragGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard !locked else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) > abs(dy) {
                    dragY = 0
                    let seconds = Double(dx) / 6.0
                    let current = controller.position
                    let total = controller.duration
                    let target = max(0, min(total > 0 ? total - 1 : current + seconds, current + seconds))
                    controller.seek(to: target)
                    hud = GestureHUD(kind: .seek, value: seconds,
                                     text: (seconds >= 0 ? "+" : "") + String(Int(seconds)) + " 秒")
                    return
                }
                if dy > 0, abs(dy) > abs(dx) * 1.2 {
                    dragY = dy
                    hud = nil
                    return
                }
                dragY = 0
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
            .onEnded { value in
                guard !locked else { return }
                if value.translation.height > 110 || value.predictedEndTranslation.height > 240 {
                    hud = nil
                    close()
                    return
                }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { dragY = 0 }
                clearHUDSoon()
            }
    }

    /// iOS 没有公开的"设置系统音量"API，业界做法是拿 MPVolumeView 里那个 UISlider 来用
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

    // MARK: - 生命周期

    private func onAppearAction() {
        controller.update(preference: PlayerKernelPreference.from(library.settings.playerKernel), rate: rate)
        controller.onEnded = { playNext(auto: true) }
        prepareVolumeSlider()
    }

    private func onDisappearAction() {
        resolveTask?.cancel()
        saveProgress(force: true)
        controller.stop()
    }

    // MARK: - 播放地址 / 切集

    private func startResolve() {
        resolveTask?.cancel()
        resolveToken += 1
        let token = resolveToken
        resolving = true
        errorText = nil
        resolveTask = Task { await resolve(token: token) }
    }

    @MainActor
    private func resolve(token: Int) async {
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
        // 源会问"现在播什么"来配弹幕；把上下文给它（只认最后一次，避免连点时给错）
        if token == resolveToken {
            PlaybackContext.shared.update(title: item.name,
                                          episodeName: episode.name,
                                          flag: request.flag,
                                          fileName: episode.url)
        }
        do {
            let (url, headers) = try await client.resolvePlay(episodeURL: episode.url,
                                                             flag: request.flag,
                                                             site: request.site)
            // ⚠️ 连点"下一集"会同时发好几个 play 请求（源解析网盘一次好几秒）：
            // 慢的那个回来了也不能覆盖现在的画面
            guard token == resolveToken else { return }
            resolving = false
            controller.update(preference: PlayerKernelPreference.from(library.settings.playerKernel), rate: rate)
            controller.load(url: url, headers: headers, title: episode.name)
            DanmakuStore.shared.clear(episodeKey: episodeKey)
            if danmakuEnabled { Task { await loadDanmaku() } }
            resumeProgress(token: token)
        } catch {
            guard token == resolveToken else { return }
            resolving = false
            errorText = "取播放地址失败：\(error.localizedDescription)"
            CatyLog.shared.warn("player", "取播放地址失败：\(error.localizedDescription)")
        }
    }

    /// 断点续播：同一集的进度超过 10 秒才跳（等播放器准备好再 seek）
    @MainActor
    private func resumeProgress(token: Int) {
        guard library.settings.rememberProgress,
              let record = library.history(for: item),
              record.episodeIndex == index,
              record.positionSec > 10 else { return }
        let target = record.positionSec
        Task {
            for _ in 0..<25 {
                if Task.isCancelled { return }
                if controller.duration > 0 { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard token == resolveToken else { return }
            controller.seek(to: target)
            CatyLog.shared.info("player", "断点续播：从 \(Int(target))s 继续")
        }
    }

    private func switchTo(_ newIndex: Int) {
        guard newIndex >= 0, newIndex < episodes.count, newIndex != index else { return }
        saveProgress(force: true)
        index = newIndex
        startResolve()
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

    private func setRate(_ value: Double) {
        rate = value
        controller.setRate(value)
        library.settings.rate = value
    }

    private func seek(by seconds: Double) {
        let current = controller.position
        let total = controller.duration
        let target = max(0, min(total > 0 ? total - 1 : current + seconds, current + seconds))
        controller.seek(to: target)
        hud = GestureHUD(kind: .seek, value: seconds,
                         text: (seconds >= 0 ? "+" : "") + String(Int(seconds)) + " 秒")
        clearHUDSoon()
    }

    private func tick() {
        guard !resolving else { return }
        saveProgress(force: false)
    }

    /// 播放位置外推：采样是 0.35s 一次，弹幕要按帧动，所以"位置 + 这之后过去的时间×倍速"
    private var extrapolatedPosition: Double {
        guard controller.isPlaying, !controller.buffering else { return controller.position }
        // 最多只外推 0.6 秒：缓冲/卡顿时不让弹幕先跑出去再被拽回来（那样是一卡一跳）
        let elapsed = min(max(Date().timeIntervalSince(controller.positionUpdatedAt), 0), 0.6)
        return controller.position + elapsed * rate
    }

    // MARK: - 弹幕

    private func toggleDanmaku() {
        danmakuEnabled.toggle()
        library.settings.danmakuEnabled = danmakuEnabled
        if danmakuEnabled, danmaku.isEmpty { Task { await loadDanmaku() } }
    }

    /// 取这一集的弹幕（源的 /danmu/auto：<剧名> + <第几集>）
    /// 解析几万条 XML 是后台线程做的（DanmakuService 那边），这里只负责把结果写回主线程的状态
    @MainActor
    private func loadDanmaku() async {
        // 弹幕接口在**这个站点所属的那个源**上（多源同进程时必须用对地址）
        guard let client, let base = client.base(for: request.site.sourceId) else { return }
        // 设置里选了"自定义远程"就用远程地址（兼容别的弹幕服务）
        let remote = library.settings.danmakuSource == "remote" ? library.settings.danmakuRemoteURL : nil
        let key = episodeKey
        let comments = await DanmakuService.comments(base: base,
                                                     name: item.name,
                                                     episode: index + 1,
                                                     remoteBase: remote)
        guard DanmakuStore.shared.episodeKey == key else { return }
        DanmakuStore.shared.set(comments, episodeKey: key)
    }

    // MARK: - 小动作

    private func startPiP() {
        guard controller.active == .system else {
            showToast("画中画只支持系统内核（设置里可切）")
            return
        }
        controller.pip.start()
    }

    private func takeScreenshot() {
        Task { @MainActor in
            let message = await controller.screenshot()
            showToast(message)
        }
    }

    private func skipIntro() {
        let seconds = max(1, library.settings.skipIntroSeconds)
        let base = controller.position
        let limit = controller.duration > 0 ? controller.duration - 1 : base + Double(seconds)
        controller.seek(to: min(limit, base + Double(seconds)))
        showToast("已跳片头 " + String(seconds) + " 秒")
    }

    private func showToast(_ text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if toast == text { toast = nil }
        }
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
            .animation(.easeInOut(duration: 0.15), value: selected)
    }
}
