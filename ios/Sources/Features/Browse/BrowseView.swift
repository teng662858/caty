//
//  BrowseView.swift
//  分类浏览：站点的完整分类列表 + 筛选项 + 翻页 + 目录条目
//
//  契约（M0 实测）：home 返回 class（分类）与 filters（筛选项）；
//  category 用 { tid, pg } 取内容；带筛选项时额外提交 { filter: "1", extend: {...} }。
//  目录条目（vod_tag=folder）点进去是**同一站点的另一个分类**（用条目 id 当 tid）。
//

import SwiftUI

/// 进入目录条目用的导航值
struct FolderTarget: Hashable {
    let site: SiteInfo
    let tid: String
    let title: String
}

struct BrowseView: View {

    let site: SiteInfo
    let client: NodeClient?
    var initialTid: String?
    var title: String?

    @State private var categories: [Category] = []
    @State private var filters: [FilterGroup] = []
    @State private var selected: [String: String] = [:]
    @State private var tid: String?
    @State private var items: [VodItem] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        List {
            if loading && items.isEmpty {
                Section { PosterSkeletonGrid(columns: 3, rows: 2).listRowInsets(EdgeInsets()) }
            }
            ForEach(items) { item in
                row(for: item)
            }
            if loading && !items.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
            if items.isEmpty && !loading && errorText == nil {
                StateView(kind: .empty("这个分类没有内容", hint: "换一个分类试试"))
                    .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.plain)
        .navigationTitle(title ?? site.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(categories) { category in
                        Button {
                            guard category.id != tid else { return }
                            tid = category.id
                            selected = [:]
                            Task { await reload() }
                        } label: {
                            Label(category.name, systemImage: category.id == tid ? "checkmark" : "circle")
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .disabled(categories.isEmpty)
            }
        }
        .safeAreaInset(edge: .top) { filterBar }
        .navigationDestination(for: VodItem.self) { item in
            DetailView(item: item, client: client)
        }
        .navigationDestination(for: FolderTarget.self) { target in
            BrowseView(site: target.site, client: client, initialTid: target.tid, title: target.title)
        }
        .task { await loadInitial() }
    }

    // MARK: - 顶部：分类 + 筛选项

    @ViewBuilder
    private var filterBar: some View {
        if categories.isEmpty && filters.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: Theme.spacingS) {
                if !categories.isEmpty { categoryRow }
                ForEach(filters) { group in filterRow(group) }
            }
            .padding(.vertical, Theme.spacingS)
            .background(.bar)
        }
    }

    private var categoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.spacingS) {
                ForEach(categories) { category in
                    Button {
                        guard category.id != tid else { return }
                        tid = category.id
                        selected = [:]
                        Task { await reload() }
                    } label: {
                        ChipLabel(text: category.name, selected: category.id == tid, compact: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.padding)
        }
    }

    private func filterRow(_ group: FilterGroup) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.spacingS) {
                Text(group.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(group.options, id: \.self) { option in
                    Button {
                        if selected[group.id] == option.value {
                            selected[group.id] = nil
                        } else {
                            selected[group.id] = option.value
                        }
                        Task { await reload() }
                    } label: {
                        ChipLabel(text: option.name,
                                  selected: selected[group.id] == option.value,
                                  compact: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.padding)
        }
    }

    // MARK: - 行

    @ViewBuilder
    private func row(for item: VodItem) -> some View {
        if item.isFolder {
            NavigationLink(value: FolderTarget(site: site, tid: item.id, title: item.name)) {
                VodRow(item: item, subtitle: "目录 · 点进去继续浏览")
            }
        } else {
            NavigationLink(value: item) {
                VodRow(item: item, subtitle: subtitle(for: item))
            }
            .onAppear {
                if item.id == items.last?.id { Task { await loadMore() } }
            }
        }
    }

    private func subtitle(for item: VodItem) -> String? {
        if let record = LibraryStore.shared.history(for: item), record.positionSec > 5 {
            return "看到 \(record.episodeName)"
        }
        return nil
    }

    // MARK: - 取数

    @MainActor
    private func loadInitial() async {
        guard let client else {
            errorText = "运行时还没就绪"
            return
        }
        guard !loading else { return }
        loading = true
        defer { loading = false }

        do {
            let home = try await client.home(site: site)
            categories = home.categories
            if let initialTid {
                tid = initialTid
            } else if tid == nil {
                tid = home.categories.first?.id
            }
            filters = tid.flatMap { home.filters[$0] } ?? []
            if !home.items.isEmpty && initialTid == nil {
                items = home.items
            }
            if let tid {
                let result = try await client.category(site: site, tid: tid, page: 1, extend: selected)
                if !result.items.isEmpty || items.isEmpty {
                    items = result.items
                    page = result.page
                    pageCount = result.pageCount
                }
            }
        } catch {
            errorText = "取不到内容：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func reload() async {
        guard let client, !loading else { return }
        loading = true
        defer { loading = false }
        items = []
        page = 1
        errorText = nil
        do {
            let result = try await client.category(site: site, tid: tid, page: 1, extend: selected)
            items = result.items
            page = result.page
            pageCount = result.pageCount
        } catch {
            errorText = "取不到内容：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func loadMore() async {
        guard let client, !loading, page < pageCount, !items.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await client.category(site: site, tid: tid, page: page + 1, extend: selected)
            let existing = Set(items.map(\.id))
            items.append(contentsOf: result.items.filter { !existing.contains($0.id) })
            page = result.page
            pageCount = result.pageCount
        } catch {
            CatyLog.shared.warn("site", "翻页失败：\(error.localizedDescription)")
        }
    }
}
