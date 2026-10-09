//
//  HomeView.swift
//  首页：站点切换 + 分类切换 + 海报墙
//
//  P5 版本（对照 design/ui-mockup.png 的首页）：海报网格、备注角标、骨架屏、五态。
//  数据来源：POST /spider/<key>/3/home（分类）+ /category（内容）—— M0 实测契约。
//

import SwiftUI

struct HomeView: View {

    @ObservedObject var coordinator: RuntimeCoordinator
    @ObservedObject private var library = LibraryStore.shared

    @State private var siteKey: String?
    @State private var categories: [Category] = []
    @State private var tid: String?
    @State private var items: [VodItem] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var loading = false
    @State private var errorText: String?

    /// 系统站点（配置中心/我的网盘/豆瓣首页这种）不作为默认站点，但保留在列表里可选
    private let systemKeys: Set<String> = ["douban", "gengxin", "baseset", "mypan"]

    private var currentSite: SiteInfo? {
        guard let siteKey else { return nil }
        return coordinator.sites.first { $0.key == siteKey }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingM) {
                    siteChips
                    if !categories.isEmpty { categoryChips }
                    content
                }
                .padding(.top, Theme.spacingS)
            }
            .navigationTitle("Caty")
            .navigationDestination(for: VodItem.self) { item in
                DetailView(item: item, client: coordinator.client)
            }
            .navigationDestination(for: FolderTarget.self) { target in
                BrowseView(site: target.site, client: coordinator.client, initialTid: target.tid, title: target.title)
            }
            .toolbar { toolbar }
            .task { await bootstrapIfNeeded() }
            .onChange(of: coordinator.sites.count) { _, _ in
                Task { await bootstrapIfNeeded(force: true) }
            }
        }
    }

    // MARK: - 站点 / 分类

    private var siteChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.spacingS) {
                ForEach(coordinator.sites) { site in
                    Button {
                        guard site.key != siteKey else { return }
                        siteKey = site.key
                        library.settings.defaultSiteKey = site.key
                        Task { await loadSite() }
                    } label: {
                        ChipLabel(text: site.name, selected: site.key == siteKey)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.padding)
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.spacingS) {
                ForEach(categories) { category in
                    Button {
                        guard category.id != tid else { return }
                        tid = category.id
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
            StateView(kind: .empty("这个分类没有内容", hint: "换个分类或换个站点试试"))
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
    }

    private var toolbar: some View {
        Button {
            Task { await reload() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .disabled(loading || siteKey == nil)
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
        errorText = nil
        do {
            let home = try await client.home(site: site)
            categories = home.categories
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
            let result = try await client.category(site: site, tid: tid, page: 1)
            items = result.items
            page = result.page
            pageCount = result.pageCount
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func loadMore() async {
        guard let site = currentSite, let client = coordinator.client,
              !loading, page < pageCount, let last = items.last else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await client.category(site: site, tid: tid, page: page + 1)
            let existing = Set(items.map(\.id))
            items.append(contentsOf: result.items.filter { !existing.contains($0.id) })
            page = result.page
            pageCount = result.pageCount
        } catch {
            CatyLog.shared.warn("site", "加载下一页失败：\(error.localizedDescription)")
        }
        _ = last
    }
}
