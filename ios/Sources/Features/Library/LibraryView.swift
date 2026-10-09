//
//  LibraryView.swift
//  片库：收藏 + 历史（含断点续播入口）
//

import SwiftUI

struct LibraryView: View {

    @ObservedObject var coordinator: RuntimeCoordinator
    @ObservedObject private var library = LibraryStore.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// iPad / 横屏：海报多铺两列（和首页同一套规则）
    private var isWideLayout: Bool { sizeClass == .regular }

    @State private var tab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("收藏（\(library.favorites.count)）").tag(0)
                    Text("历史（\(library.history.count)）").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.padding)
                .padding(.vertical, Theme.spacingS)

                if tab == 0 { favoritesView } else { historyView }
            }
            .navigationTitle("片库")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: VodItem.self) { item in
                DetailView(item: item, site: site(for: item), client: coordinator.client)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if tab == 0 {
                            Button("清空收藏", role: .destructive) { library.clearFavorites() }
                        } else {
                            Button("清空历史", role: .destructive) { library.clearHistory() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    // MARK: - 收藏

    @ViewBuilder
    private var favoritesView: some View {
        if library.favorites.isEmpty {
            StateView(kind: .empty("还没有收藏", hint: "在详情页点「收藏」就会出现在这里"))
        } else {
            ScrollView {
                LazyVGrid(columns: Theme.posterColumns(library.settings.gridColumns, wide: isWideLayout),
                          spacing: Theme.spacingM) {
                    ForEach(library.favorites) { record in
                        NavigationLink(value: record.item.asVodItem) {
                            PosterCard(item: record.item.asVodItem)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("取消收藏", role: .destructive) { library.removeFavorite(id: record.id) }
                        }
                    }
                }
                .padding(.horizontal, Theme.padding)
                .padding(.bottom, Theme.padding)
            }
        }
    }

    // MARK: - 历史

    @ViewBuilder
    private var historyView: some View {
        if library.history.isEmpty {
            StateView(kind: .empty("还没有观看记录", hint: "看过的片会自动记在这里，支持断点续播"))
        } else {
            List {
                ForEach(library.history) { record in
                    NavigationLink(value: record.item.asVodItem) {
                        historyRow(record)
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { library.removeHistory(id: record.id) }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func historyRow(_ record: HistoryRecord) -> some View {
        HStack(alignment: .top, spacing: Theme.spacingM) {
            PosterImage(urlString: record.item.pic)
                .frame(width: 54, height: 81)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.item.name).font(.body).lineLimit(2)
                Text(record.episodeName + " · 看到 " + Self.timeText(record.positionSec))
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                ProgressView(value: record.progress)
                    .tint(Theme.accent)
                Text(Self.relativeText(record.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 工具

    /// 从当前站点目录里找回站点信息（收藏/历史只存了 key）
    /// ⚠️ 多源同时跑时，不同源可能有同名 key 的站点 → 先按 (key, sourceId) 精确匹配
    private func site(for item: VodItem) -> SiteInfo? {
        coordinator.sites.first { $0.key == item.siteKey && $0.sourceId == item.sourceId }
            ?? coordinator.sites.first { $0.key == item.siteKey }
    }

    private static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        if m >= 60 {
            return String(format: "%d:%02d:%02d", m / 60, m % 60, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private static func relativeText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
