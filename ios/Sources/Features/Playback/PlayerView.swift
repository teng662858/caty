//
//  PlayerView.swift
//  播放页（P5）：进度记忆 / 断点续播 / 倍速 / 上一集下一集 / 播完自动下一集
//
//  返回手势（2026-10-10 用户反馈"播放页要能返回上一页"）：
//  全屏弹出没法用手势返回，这里自己加两个——
//    · 在画面上**向下滑** → 关闭播放页（松手超过阈值就关，跟抖音那套一样）
//    · **从屏幕左边缘往右滑** → 同样关闭（系统"返回上一页"的手感）
//

import SwiftUI
import AVKit

struct PlayerView: View {

    let request: PlayRequest
    let client: NodeClient?

    @StateObject private var engine = AVPlayerEngine()
    @ObservedObject private var library = LibraryStore.shared

    @State private var index: Int
    @State private var rate: Double
    @State private var resolving = true
    @State private var errorText: String?
    @State private var position: Double = 0
    @State private var duration: Double = 0
    /// 跟手位移：下滑关闭 / 左边缘返回各一个（用于拖的时候页面跟着动）
    @State private var dragY: CGFloat = 0
    @State private var dragX: CGFloat = 0

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
        .task { await resolve() }
        .onDisappear {
            saveProgress(force: true)
            engine.stop()
        }
        .onReceive(ticker) { _ in tick() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            // ⚠️ 这个通知是**全局**的：必须确认是自己的当前条目发的，
            // 否则别的播放器（或上一集残留）播完都会触发"自动下一集"，
            // 一旦某集秒失败就会连环跳到最后一集（真机踩过）。
            guard let finished = notification.object as? AVPlayerItem,
                  finished === engine.player.currentItem else { return }
            playNext(auto: true)
        }
    }

    // MARK: - 返回手势

    /// 关闭播放页（按钮和手势都走这里）
    private func close() {
        saveProgress(force: true)
        engine.stop()
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

    /// 画面上向下滑：只认"竖直向下"的位移，避免和进度条/横向滑动打架
    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                let dy = value.translation.height
                let dx = value.translation.width
                dragY = (dy > 0 && abs(dy) > abs(dx) * 1.2) ? dy : 0
            }
            .onEnded { value in
                let dy = value.translation.height
                if dy > 110 || value.predictedEndTranslation.height > 240 {
                    close()
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { dragY = 0 }
                }
            }
    }

    // MARK: - 视频区

    private var videoArea: some View {
        ZStack {
            Color.black
            VideoPlayer(player: engine.player)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .gesture(dismissDragGesture)
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
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
            if let lastError = engine.lastError {
                Text("播放器：\(lastError)").font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    // MARK: - 进度

    private var progressRow: some View {
        VStack(spacing: 2) {
            Slider(value: Binding(get: { position },
                                  set: { position = $0 }),
                   in: 0...max(1, duration)) { editing in
                if !editing { engine.seek(to: position) }
            }
            HStack {
                Text(Self.timeText(position)).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(Self.timeText(duration)).font(.caption2).foregroundStyle(.secondary)
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

            Button { engine.toggle() } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
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
        engine.rate = Float(value)
        library.settings.rate = value
        engine.play()
    }

    private func switchTo(_ newIndex: Int) {
        guard newIndex >= 0, newIndex < episodes.count, newIndex != index else { return }
        saveProgress(force: true)
        index = newIndex
        position = 0
        duration = 0
        Task { await resolve() }
    }

    private func playNext(auto: Bool) {
        guard index + 1 < episodes.count else {
            if auto { engine.pause() }
            return
        }
        // 自动下一集只认"真的看到结尾"（时长合理且进度接近末尾），
        // 避免播放失败/秒退时连环跳集 —— 手动点下一集不受此限制
        if auto {
            guard duration > 30, position > duration * 0.9 else {
                CatyLog.shared.info("player", "忽略自动下一集（duration=\(Int(duration))s position=\(Int(position))s）")
                return
            }
        }
        switchTo(index + 1)
    }

    private func seek(by seconds: Double) {
        let target = max(0, min(duration > 0 ? duration - 1 : position + seconds, position + seconds))
        position = target
        engine.seek(to: target)
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
            engine.rate = Float(rate)
            engine.load(url: url, headers: headers, title: episode.name)

            // 断点续播：同一集的进度超过 10 秒才跳（等播放器准备好再 seek）
            if library.settings.rememberProgress,
               let record = library.history(for: item),
               record.episodeIndex == index,
               record.positionSec > 10 {
                let target = record.positionSec
                position = target
                Task {
                    // 等播放器真的就绪再跳：在缓冲阶段 seek 容易造成音画错位
                    for _ in 0..<25 {
                        if engine.player.currentItem?.status == .readyToPlay { break }
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    engine.seek(to: target)
                    CatyLog.shared.info("player", "断点续播：从 \(Int(target))s 继续")
                }
            }
        } catch {
            errorText = "取播放地址失败：\(error.localizedDescription)"
            CatyLog.shared.warn("player", "取播放地址失败：\(error.localizedDescription)")
        }
    }

    private func tick() {
        guard !resolving, engine.currentURL != nil else { return }
        let current = engine.player.currentTime().seconds
        if current.isFinite, current >= 0 { position = current }
        if let total = engine.player.currentItem?.duration.seconds, total.isFinite, total > 0 {
            duration = total
        }
        saveProgress(force: false)
    }

    private func saveProgress(force: Bool) {
        guard library.settings.rememberProgress, let episode else { return }
        guard duration > 0 || force else { return }
        library.updateHistory(item: item,
                              episodeIndex: index,
                              episodeName: episode.name,
                              position: position,
                              duration: duration,
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
