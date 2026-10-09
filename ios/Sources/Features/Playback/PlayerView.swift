//
//  PlayerView.swift
//  播放页（P5）：进度记忆 / 断点续播 / 倍速 / 上一集下一集 / 播完自动下一集
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

    var body: some View {
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
        .task { await resolve() }
        .onDisappear {
            saveProgress(force: true)
            engine.stop()
        }
        .onReceive(ticker) { _ in tick() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            playNext(auto: true)
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
        HStack(spacing: Theme.spacingL) {
            Button { switchTo(index - 1) } label: {
                Image(systemName: "backward.end.fill")
            }
            .disabled(index <= 0)

            Button { engine.toggle() } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }

            Button { playNext(auto: false) } label: {
                Image(systemName: "forward.end.fill")
            }
            .disabled(index >= episodes.count - 1)

            Button { seek(by: -15) } label: { Image(systemName: "gobackward.15") }
            Button { seek(by: 15) } label: { Image(systemName: "goforward.15") }

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
                    .font(.footnote)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
    }

    // MARK: - 选集条

    private var episodeStrip: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            Text("选集（\(episodes.count)）· \(request.flag)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.spacingS) {
                    ForEach(Array(episodes.enumerated()), id: \.element.id) { i, ep in
                        Button { switchTo(i) } label: {
                            ChipLabel(text: ep.name, selected: i == index, compact: true)
                        }
                        .buttonStyle(.plain)
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
        if index + 1 < episodes.count {
            switchTo(index + 1)
        } else if auto {
            engine.pause()
        }
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
                    try? await Task.sleep(nanoseconds: 800_000_000)
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
