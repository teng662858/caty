//
//  HomeView.swift
//  首页：源选择（左上角菜单）→ 源的分类（第一排）→ 该分类的筛选项 → 海报墙
//
//  布局按用户反馈改过（2026-10-09）：
//    源不再是横排胶囊，而是左上角菜单（抽屉式）；
//    第一排是**源的分类**，点分类后在下面才出现**筛选项**（源返回的 filters）。
//  数据：POST /spider/<key>/3/home（分类 + filters）+ /category（内容，带 extend 筛选）
//

import SwiftUI

struct HomeView: View {

    @ObservedObject var coordinator: RuntimeCoordinator
    @ObservedObject private var library = LibraryStore.shared

    @State private var siteKey: String?
    @State private var categories: [Category] = []
    @State private var categoryFilters: [String: [FilterGroup]] = [:]
    @State private var tid: String?
    @State private var selected: [String: String] = [:]
    @State private var items: [VodItem] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var loading = false
    @State private var errorText: String?

    /// 系统站点（配置中心/我的网盘/豆瓣首页这类）不作为默认站点，但保留在菜单里
    private let systemKeys: Set<String> = ["douban", "gengxin", "baseset", "mypan"]

    private var currentSite: SiteInfo? {
        guard let siteKey else { return nil }
        return coordinator.sites.first { $0.key == siteKey }
    }

    private var currentFilters: [FilterGroup] {
        guard let tid else { return [] }
        return categoryFilters[tid] ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingM) {
                    if !categories.isEmpty { categoryChips }
                    if !currentFilters.isEmpty { filterRows }
                    content
                }
                .padding(.top, Theme.spacingS)
            }
            .navigationTitle(currentSite?.name ?? "Caty")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: VodItem.self) { item in
                DetailView(item: item, site: currentSite, client: coordinator.client)
            }
            .navigationDestination(for: FolderTarget.self) { target in
                BrowseView(site: target.site, client: coordinator.client,
                           initialTid: target.tid, title: target.title)
            }
            .toolbar { toolbar }
            .task { await bootstrapIfNeeded() }
            .onChange(of: coordinator.sites.count) { _, _ in
                Task { await bootstrapIfNeeded(force: true) }
            }
        }
    }

    // MARK: - 源（左上角菜单）

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                ForEach(coordinator.sites) { site in
                    Button {
                        guard site.key != siteKey else { return }
                        siteKey = site.key
                        library.settings.defaultSiteKey = site.key
                        Task { await loadSite() }
                    } label: {
                        Label(site.name, systemImage: site.key == siteKey ? "checkmark" : "circle")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.stack")
                    Text(currentSite?.name ?? "选择源")
                        .font(.footnote)
                        .lineLimit(1)
                }
            }
            .disabled(coordinator.sites.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await loadSite() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(loading || siteKey == nil)
        }
    }

    // MARK: - 第一排：源的分类

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.spacingS) {
                ForEach(categories) { category in
                    Button {
                        guard category.id != tid else { return }
                        tid = category.id
                        selected = [:]
                        Task { await reload() }
                    } label: {
                        ChipLabel(text: category.name, selected: category.id == tid)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.padding)
        }
    }

    // MARK: - 第二排起：筛选项（只显示当前分类的）

    private var filterRows: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            ForEach(currentFilters) { group in
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
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if coordinator.sites.isEmpty {
            runtimeState
        } else if loading && items.isEmpty {
            PosterSkeletonGrid(columns: library.settings.gridColumns)
        } else if let errorText, items.isEmpty {
            StateView(kind: .failure("取不到内容", hint: errorText)) {
                Task { await reload() }
            }
        } else if items.isEmpty {
            StateView(kind: .empty("这个分类没有内容", hint: "换个分类或换个源试试"))
        } else {
            grid
        }
    }

    private var runtimeState: some View {
        StateView(kind: .loading(coordinator.runtime.state == .ready
                                 ? "正在读取站点目录…"
                                 : "运行时准备中（\(coordinator.runtime.state.label)）"))
    }

    private var grid: some View {
        LazyVGrid(columns: Theme.posterColumns(library.settings.gridColumns), spacing: Theme.spacingM) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    PosterCard(item: item, showRemarks: true)
                }
                .buttonStyle(.plain)
                .onAppear {
                    if item.id == items.last?.id { Task { await loadMore() } }
                }
            }
        }
        .padding(.horizontal, Theme.padding)
        .padding(.bottom, Theme.padding)
    }

    // MARK: - 取数

    @MainActor
    private func bootstrapIfNeeded(force: Bool = false) async {
        guard !coordinator.sites.isEmpty else { return }
        if !force, siteKey != nil { return }
        if siteKey == nil {
            let preferred = library.settings.defaultSiteKey.flatMap { key in
                coordinator.sites.first { $0.key == key }
            }
            let fallback = coordinator.sites.first { !systemKeys.contains($0.key) } ?? coordinator.sites.first
            siteKey = (preferred ?? fallback)?.key
        }
        await loadSite()
    }

    @MainActor
    private func loadSite() async {
        guard let site = currentSite, let client = coordinator.client, !loading else { return }
        loading = true
        defer { loading = false }
        items = []
        categories = []
        categoryFilters = [:]
        selected = [:]
        errorText = nil
        do {
            let home = try await client.home(site: site)
            categories = home.categories
            categoryFilters = home.filters
            items = home.items
            tid = home.categories.first?.id
            page = 1
            pageCount = 1
            if let first = tid {
                let result = try await client.category(site: site, tid: first, page: 1)
                items = result.items
                page = result.page
                pageCount = result.pageCount
            }
            if items.isEmpty { errorText = "这个站点没有返回内容" }
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func reload() async {
        guard let site = currentSite, let client = coordinator.client, !loading else { return }
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
            if items.isEmpty { errorText = "这个筛选组合没有内容" }
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func loadMore() async {
        guard let site = currentSite, let client = coordinator.client,
              !loading, page < pageCount, items.count > 1 else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await client.category(site: site, tid: tid, page: page + 1, extend: selected)
            let existing = Set(items.map(\.id))
            items.append(contentsOf: result.items.filter { !existing.contains($0.id) })
            page = result.page
            pageCount = result.pageCount
        } catch {
            CatyLog.shared.warn("site", "加载下一页失败：\(error.localizedDescription)")
        }
    }
}
