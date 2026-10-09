//
//  DetailView.swift
//  详情页（P4 粗版）：简介 + 线路切换 + 选集 → 播放
//

import SwiftUI

struct DetailView: View {

    let item: VodItem
    let site: SiteInfo
    let client: NodeClient?

    @State private var detail: VodDetail?
    @State private var sourceIndex = 0
    @State private var loading = true
    @State private var errorText: String?

    private var currentEpisodes: [Episode] {
        guard let detail, sourceIndex < detail.episodes.count else { return [] }
        return detail.episodes[sourceIndex]
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    poster
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.name).font(.headline)
                        if let remarks = item.remarks {
                            Text(remarks).font(.caption).foregroundStyle(.secondary)
                        }
                        if let typeName = item.typeName {
                            Text(typeName).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let year = item.year {
                            Text(year).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let actor = detail?.actor, !actor.isEmpty {
                            Text("主演：\(actor)").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }

            if detail == nil && loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }

            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }

            if let detail, !detail.episodes.isEmpty {
                if detail.episodes.count > 1 {
                    Section("播放线路（\(detail.episodes.count)）") {
                        Picker("线路", selection: $sourceIndex) {
                            ForEach(Array(detail.episodes.indices), id: \.self) { index in
                                Text(detail.sourceName(at: index)).tag(index)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section("选集（\(currentEpisodes.count)）") {
                    if currentEpisodes.isEmpty {
                        Text("这条线路没有剧集").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 8) {
                            ForEach(currentEpisodes) { episode in
                                NavigationLink(value: episode) {
                                    Text(episode.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 7)
                                        .background(Color.secondary.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else if !loading && errorText == nil {
                Text("这个条目没有可播的剧集（可能是目录项）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let content = detail?.content, !content.isEmpty {
                Section("简介") {
                    Text(content)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(20)
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Episode.self) { episode in
            PlayerView(episode: episode,
                       flag: detail?.sourceName(at: sourceIndex) ?? "线路 1",
                       site: site,
                       client: client)
        }
        .task { await load() }
    }

    private var poster: some View {
        AsyncImage(url: item.pic.flatMap { URL(string: $0) }) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Color.secondary.opacity(0.15).overlay(
                    Image(systemName: "film").foregroundStyle(.secondary)
                )
            }
        }
        .frame(width: 92, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

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
            detail = try await client.detail(site: site, ids: item.id)
            if detail == nil {
                errorText = "源没有返回这个条目的详情"
            }
        } catch {
            errorText = "详情取不到：\(error.localizedDescription)"
        }
    }
}
