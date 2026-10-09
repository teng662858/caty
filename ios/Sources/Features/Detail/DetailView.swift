//
//  DetailView.swift
//  详情页（P5）：海报头部 + 收藏 + 继续观看 + 线路切换 + 选集网格 + 简介
//

import SwiftUI

/// 一次播放请求（把"播哪一集、整条列表、哪个站点"打包传给播放页）
struct PlayRequest: Identifiable, Hashable {
    let item: VodItem
    let episodes: [Episode]
    let index: Int
    let flag: String
    let site: SiteInfo

    var id: String { item.id + "#" + String(index) + "#" + flag + "#" + site.key }
}

struct DetailView: View {

    let item: VodItem
    var site: SiteInfo? = nil
    let client: NodeClient?

    @ObservedObject private var library = LibraryStore.shared

    @State private var detail: VodDetail?
    @State private var sourceIndex = 0
    @State private var loading = true
    @State private var errorText: String?

    /// 播放用**全屏弹出**而不是导航推入：
    /// 之前用 NavigationLink 时，连点选集会在导航栈里堆出多个播放页，
    /// 结果"退一次只退一集"、还会误以为跳到了最后一集（真机踩过）。
    @State private var playing: PlayRequest?
    @State private var isPresenting = false

    /// 站点信息可能没传进来（例如从收藏/历史进入）→ 用条目自带的 key 兜底
    private var effectiveSite: SiteInfo {
        if let site { return site }
        return SiteInfo(key: item.siteKey,
                        name: item.siteKey,
                        type: 3,
                        api: NodeRoute.scheme + "/spider/\(item.siteKey)/3",
                        searchable: true,
                        enabled: true,
                        group: nil,
                        ext: nil,
                        sourceId: item.sourceId)
    }

    private var episodes: [Episode] {
        guard let detail, sourceIndex < detail.episodes.count else { return [] }
        return detail.episodes[sourceIndex]
    }

    private var flag: String {
        detail?.sourceName(at: sourceIndex) ?? "线路 1"
    }

    var body: some View {
        List {
            headerSection
            if loading && detail == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
            if let detail, detail.episodes.count > 1 {
                sourceSection(detail)
            }
            if !episodes.isEmpty {
                episodeSection
            } else if !loading && detail != nil && errorText == nil {
                Text(item.isFolder ? "这是一个目录，点上面的「进入目录」继续浏览" : "这个条目没有可播的剧集")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let content = detail?.content, !content.isEmpty {
                Section("简介") {
                    Text(content)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(30)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playing) { request in
            PlayerView(request: request, client: client)
        }
        .navigationDestination(for: FolderTarget.self) { target in
            BrowseView(site: target.site, client: client, initialTid: target.tid, title: target.title)
        }
        .task { await load() }
    }

    // MARK: - 头部

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.spacingM) {
                HStack(alignment: .top, spacing: Theme.spacingM) {
                    PosterImage(urlString: item.pic)
                        .frame(width: 100, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.posterRadius))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name).font(.headline).lineLimit(3)
                        if let remarks = item.remarks {
                            Text(remarks).font(.caption).foregroundStyle(.secondary)
                        }
                        if let meta = metaLine {
                            Text(meta).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let actor = detail?.actor, !actor.isEmpty {
                            Text("主演：\(actor)").font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    Spacer(minLength: 0)
                }
                // ⚠️ 这几个按钮**单独占一行**（2026-10-10 用户反馈"继续观看的字位置不对"）：
                // 以前它们挤在海报右边那一栏里，字一长就折成两行、跟海报对不齐
                actions
            }
            .padding(.vertical, 4)
        }
    }

    private var metaLine: String? {
        var parts: [String] = []
        if let typeName = item.typeName, !typeName.isEmpty { parts.append(typeName) }
        if let year = item.year, !year.isEmpty { parts.append(year) }
        if let area = detail?.area, !area.isEmpty { parts.append(area) }
        if let director = detail?.director, !director.isEmpty { parts.append("导演 " + director) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actions: some View {
        // ⚠️ 两个按钮**等宽平分**，内容各自居中（用户反馈"继续观看的字不在胶囊中间"）：
        // 以前按钮按内容自适应宽度 + 末尾有个 Spacer，宽的那个看着就像"文字偏在一边"。
        HStack(spacing: Theme.spacingS) {
            Button {
                library.toggleFavorite(item)
            } label: {
                Label(library.isFavorite(item) ? "已收藏" : "收藏",
                      systemImage: library.isFavorite(item) ? "heart.fill" : "heart")
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(library.isFavorite(item) ? .pink : Theme.accent)

            if let record = library.history(for: item), record.positionSec > 5,
               record.episodeIndex >= 0, record.episodeIndex < episodes.count {
                Button {
                    present(index: record.episodeIndex)
                } label: {
                    Label("继续观看 \(record.episodeName)", systemImage: "play.circle")
                        .font(.subheadline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            } else {
                Button {
                    present(index: 0)
                } label: {
                    Label("开始播放", systemImage: "play.circle")
                        .font(.subheadline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(episodes.isEmpty)
            }

            if item.isFolder {
                NavigationLink(value: FolderTarget(site: effectiveSite, tid: item.id, title: item.name)) {
                    Label("进入目录", systemImage: "folder")
                        .font(.subheadline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - 线路 / 选集

    private func sourceSection(_ detail: VodDetail) -> some View {
        Section("播放线路（\(detail.episodes.count)）") {
            Picker("线路", selection: $sourceIndex) {
                ForEach(Array(detail.episodes.indices), id: \.self) { index in
                    Text(detail.sourceName(at: index)).tag(index)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var episodeSection: some View {
        Section("选集（\(episodes.count)）") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                    Button {
                        present(index: index)
                    } label: {
                        episodeLabel(index: index, episode: episode)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func episodeLabel(index: Int, episode: Episode) -> some View {
        let record = library.history(for: item)
        let watching = record?.episodeIndex == index && (record?.positionSec ?? 0) > 5
        return Text(episode.name)
            .font(.caption)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(watching ? Theme.accent.opacity(0.22) : Color.secondary.opacity(0.12))
            .foregroundStyle(watching ? Theme.accent : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func playRequest(index: Int, episode: Episode) -> PlayRequest {
        PlayRequest(item: item, episodes: episodes, index: index, flag: flag, site: effectiveSite)
    }

    /// 全屏弹出播放页（带 0.7 秒防连点，避免连开多个播放页）
    private func present(index: Int) {
        guard index >= 0, index < episodes.count, !isPresenting else { return }
        isPresenting = true
        playing = playRequest(index: index, episode: episodes[index])
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            isPresenting = false
        }
    }

    // MARK: - 取数

    @MainActor
    private func load() async {
        guard let client else {
            loading = false
            errorText = "运行时还没就绪"
            return
        }
        loading = true
        defer { loading = false }
        do {
            let result = try await client.detail(site: effectiveSite, ids: item.id)
            detail = result
            if result == nil, !item.isFolder {
                errorText = "源没有返回这个条目的详情"
            }
            // 有历史就默认跳到看过的线路
            if let record = library.history(for: item), let detail, record.episodeIndex < (detail.episodes.first?.count ?? 0) {
                sourceIndex = 0
            }
        } catch {
            errorText = "详情取不到：\(error.localizedDescription)"
        }
    }
}
