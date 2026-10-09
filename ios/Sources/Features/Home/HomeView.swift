//
//  HomeView.swift
//  首页：源选择（左上角）→ 源的分类（第一排）→ 该分类的筛选项 → 海报墙
//
//  布局按用户反馈改过（2026-10-09）：
//    源不再是横排胶囊，而是左上角菜单（抽屉式）；
//    第一排是**源的分类**，点分类后在下面才出现**筛选项**（源返回的 filters）。
//  2026-10-10 用户反馈：左边角源菜单太窄 → 改成 2 列的弹窗；整体字号 +1 号。
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
    @State private var showSourcePicker = false

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
            .sheet(isPresented: $showSourcePicker) {
                SourcePickerSheet(sites: coordinator.sites, currentKey: siteKey) { site in
                    guard site.key != siteKey else { return }
                    siteKey = site.key
                    library.settings.defaultSiteKey = site.key
                    Task { await loadSite() }
                }
            }
            .task { await bootstrapIfNeeded() }
            .onChange(of: coordinator.sites.count) { _, _ in
                Task { await bootstrapIfNeeded(force: true) }
            }
        }
    }

    // MARK: - 分类下面：当前分类的筛选项（源返回多少就显示多少）

    private var filterRows: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            ForEach(currentFilters) { group in
                filterRow(group)
            }
        }
    }

    private func filterRow(_ group: FilterGroup) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.spacingS) {
                Text(group.name)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(group.options, id: \.self) { option in
                    filterChip(group: group, option: option)
                }
            }
            .padding(.horizontal, Theme.padding)
        }
    }

    private func filterChip(group: FilterGroup, option: FilterOption) -> some View {
        let isOn = selected[group.id] == option.value
        return Button {
            if isOn {
                selected[group.id] = nil
            } else {
                selected[group.id] = option.value
            }
            Task { await reload() }
        } label: {
            ChipLabel(text: option.name, selected: isOn, compact: true, large: true)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 源（左上角：点开是 2 列的源列表）

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showSourcePicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.stack")
                    Text(currentSite?.name ?? "选择源")
                        .font(.subheadline)
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
                        ChipLabel(text: category.name, selected: category.id == tid, large: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.padding)
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
            StateView(kind: .failure("取不到内容", hint: "源返回：\(errorText)")) {
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
                    PosterCard(item: item, showRemarks: true, titleFont: .footnote)
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

// MARK: - 源列表（2 列，用户反馈原菜单太窄）

/// 这个源实测有 90+ 个站点，原来的下拉菜单一行一个、只能看半截名字；
/// 改成弹窗里 2 列铺开，一眼能看全。
private struct SourcePickerSheet: View {

    let sites: [SiteInfo]
    let currentKey: String?
    let onPick: (SiteInfo) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: Theme.spacingM),
        GridItem(.flexible(), spacing: Theme.spacingM)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: Theme.spacingM) {
                    ForEach(sites) { site in
                        Button {
                            onPick(site)
                            dismiss()
                        } label: {
                            cell(site)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Theme.padding)
            }
            .navigationTitle("选择源（\(sites.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func cell(_ site: SiteInfo) -> some View {
        let isOn = site.key == currentKey
        return HStack(spacing: 6) {
            Text(site.name)
                .font(.subheadline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if isOn {
                Image(systemName: "checkmark.circle.fill").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isOn ? Theme.accent.opacity(0.18) : Color.secondary.opacity(0.10))
        .foregroundStyle(isOn ? Theme.accent : Color.primary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

