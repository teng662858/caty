//
//  PlayerView.swift
//  播放页（P4 粗版）：AVPlayer + 最简控制条
//
//  目标只有一个：**画面出来**。进度记忆/倍速/手势/弹幕都是 P5/P6 的事。
//

import SwiftUI
import AVKit

struct PlayerView: View {

    let episode: Episode
    let flag: String
    let site: SiteInfo
    let client: NodeClient?

    @StateObject private var engine = AVPlayerEngine()
    @State private var resolving = true
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: engine.player)
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(Color.black)

            List {
                Section("正在播放") {
                    Text(episode.name).font(.headline)
                    if resolving {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在取播放地址…").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let url = engine.currentURL {
                        Text(url.absoluteString)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    if let lastError = engine.lastError {
                        Text("播放器报错：\(lastError)").font(.footnote).foregroundStyle(.red)
                    }
                    if let errorText {
                        Text(errorText).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("控制") {
                    HStack {
                        Button {
                            engine.toggle()
                        } label: {
                            Label(engine.isPlaying ? "暂停" : "播放",
                                  systemImage: engine.isPlaying ? "pause.fill" : "play.fill")
                        }
                        Spacer()
                        Button {
                            engine.seek(to: 0)
                        } label: {
                            Label("重头播", systemImage: "gobackward")
                        }
                    }
                    Text("黑屏但有声音 = 编码 AVPlayer 不支持（记下来，P6 上 libmpv）；一直转圈 = 多半要 Referer（见 docs/03 报错表 15–16 条）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(episode.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await resolve() }
        .onDisappear { engine.stop() }
    }

    @MainActor
    private func resolve() async {
        guard let client else {
            resolving = false
            errorText = "运行时还没就绪"
            return
        }
        resolving = true
        defer { resolving = false }
        do {
            let (url, headers) = try await client.resolvePlay(episodeURL: episode.url, flag: flag, site: site)
            engine.load(url: url, headers: headers, title: episode.name)
        } catch {
            errorText = "取播放地址失败：\(error.localizedDescription)"
            CatyLog.shared.warn("player", "取播放地址失败：\(error.localizedDescription)")
        }
    }
}
