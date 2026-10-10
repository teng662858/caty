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
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// iPad / 横屏：海报多铺两列（同一个"每行 3 个"设置在 iPad 上不会显得稀稀拉拉）
    private var isWideLayout: Bool { sizeClass == .regular }
    private var wideColumnCount: Int { library.settings.gridColumns + (isWideLayout ? 2 : 0) }

    /// 当前选中的站点：用 SiteInfo.id（= sourceId|key）——多源同时跑时 key 可能重名
    @State private var siteId: String?
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
    /// 站点 → 它的分类/筛选项（问过一次就存下来；切回同一个站点时只发 category 请求）
    @State private var siteMenus: [String: SiteMenus] = [:]
    /// 取数任务：切站点时把上一个取消掉（"最后点的那次说了算"）
    @State private var loadTask: Task<Void, Never>?
    /// 每次"要显示的东西"换一次就 +1；回来晚了的旧请求看到号码不对就把结果丢掉
    @State private var loadToken = 0
    /// 载入超过 3 秒才提示"第一次打开这个站点要慢一点"
    @State private var slowHint = false

    /// 系统站点（配置中心/我的网盘/豆瓣首页这类）不作为默认站点，但保留在菜单里
    private var systemKeys: Set<String> { RuntimeCoordinator.systemSiteKeys }

    private var currentSite: SiteInfo? {
        guard let siteId else { return nil }
        return coordinator.sites.first { $0.id == siteId }
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
            .navigationTitle("")
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
                SourcePickerSheet(groups: sourceGroups, currentId: siteId) { site in
                    switchSite(site)
                }
            }
            .task { bootstrap() }
            .onChange(of: coordinator.sites.count) { _, _ in
                handleSitesChanged()
            }
        }
    }

    /// 站点按"来自哪个源"分组（多源同时跑时，源列表就是这个并集）
    private var sourceGroups: [SourcePickerSheet.Group] {
        var order: [String] = []
        var buckets: [String: [SiteInfo]] = [:]
        for site in coordinator.sites {
            if buckets[site.sourceId] == nil { order.append(site.sourceId) }
            buckets[site.sourceId, default: []].append(site)
        }
        return order.map { id in
            let name = coordinator.records.first { $0.id == id }?.displayName ?? id
            return SourcePickerSheet.Group(id: id, name: name, sites: buckets[id] ?? [])
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
            reloadCategory()
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
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.stack")
                    Text(currentSite?.name ?? "选择源")
                        .font(.headline)
                        .fontWeight(.bold)
                        .lineLimit(1)
                }
            }
            .disabled(coordinator.sites.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                reloadCategory()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(loading || siteId == nil)
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
                        reloadCategory()
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
            VStack(spacing: Theme.spacingM) {
                loadingBanner
                PosterSkeletonGrid(columns: wideColumnCount)
            }
        } else if isSearchOnlySite {
            // 体检确认过：这些站点（"搜索|xxx"、部分"🏠"类）本来就不返回分类列表，
            // 它们的工作方式是"去搜索页搜片名"——不该显示成"取不到内容"吓用户
            StateView(kind: .empty("这是搜索型站点",
                                   hint: "它没有分类列表，请到「搜索」页输入片名来用它")) {
                reloadCategory()
            }
        } else if let errorText, items.isEmpty {
            StateView(kind: .failure("取不到内容", hint: "源返回：\(errorText)")) {
                reloadCategory()
            }
        } else if items.isEmpty {
            StateView(kind: .empty("这个分类没有内容", hint: "换个分类或换个源试试"))
        } else {
            VStack(alignment: .leading, spacing: Theme.spacingS) {
                // 换源时**不清空旧列表**，只在上面挂一条"正在载入"——不然会白屏一下，看着像卡死
                if loading { loadingBanner }
                grid
            }
        }
    }

    /// 搜索型站点：没有任何分类、但声明可搜索（"搜索|百度"这类）
    private var isSearchOnlySite: Bool {
        guard let site = currentSite else { return false }
        return categories.isEmpty && items.isEmpty && errorText == nil && site.searchable
    }

    /// "正在载入某某站点…"（换源/换分类时的即时反馈）——第一次打开某个站点要等它解析上游地址，
    /// 所以挂一个"取消"，用户不用干等（用户原话："切换源直接卡死"）
    private var loadingBanner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("正在载入 \(currentSite?.name ?? "站点")…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if slowHint {
                    Text("这个站点第一次打开要先解析它的上游地址，会慢一点")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button("取消") { cancelLoad() }
                .font(.footnote)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, Theme.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var runtimeState: some View {
        StateView(kind: .loading(coordinator.runtime.state == .ready
                                 ? "正在读取站点目录…"
                                 : "运行时准备中（\(coordinator.runtime.state.label)）"))
    }

    private var grid: some View {
        LazyVGrid(columns: Theme.posterColumns(library.settings.gridColumns, wide: isWideLayout), spacing: Theme.spacingM) {
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

    /// 首次进入：挑一个默认站点（上次用的优先）
    private func bootstrap() {
        guard !coordinator.sites.isEmpty, siteId == nil else { return }
        let preferred = library.settings.defaultSiteKey.flatMap { key in
            coordinator.sites.first { $0.key == key }
        }
        let fallback = coordinator.sites.first { !systemKeys.contains($0.key) } ?? coordinator.sites.first
        guard let target = preferred ?? fallback else { return }
        siteId = target.id
        startSiteLoad(keepItems: false)
    }

    /// 站点列表变了（新源起来 / 某个源被停掉）：选中的那个还在就什么都不做
    /// —— 不要打断用户刚发起的切换
    private func handleSitesChanged() {
        guard !coordinator.sites.isEmpty else { return }
        if let siteId, coordinator.sites.contains(where: { $0.id == siteId }) { return }
        let fallback = coordinator.sites.first { !systemKeys.contains($0.key) } ?? coordinator.sites.first
        guard let target = fallback else { return }
        siteId = target.id
        startSiteLoad(keepItems: false)
    }

    /// 切站点：**最后点的那次说了算**。
    ///
    /// 旧写法是 `guard !loading else { return }`：正在载入时再点别的站点会被**直接丢掉**，
    /// 于是标题换了、内容还是旧站点的、也没有任何提示 —— 用户看到的就是"卡死"。
    private func switchSite(_ site: SiteInfo) {
        guard site.id != siteId else { return }
        siteId = site.id
        library.settings.defaultSiteKey = site.key
        CatyLog.shared.info("site", "切换站点 → \(site.name)")
        startSiteLoad(keepItems: false)
    }

    /// 换分类 / 换筛选 / 点刷新：同一个站点，**保留旧内容**避免白屏
    private func reloadCategory() {
        guard siteId != nil else { return }
        startSiteLoad(keepItems: true)
    }

    private func startSiteLoad(keepItems: Bool) {
        loadTask?.cancel()
        loadToken += 1
        let token = loadToken
        loading = true
        errorText = nil
        slowHint = false
        if !keepItems {
            // 换站点：旧列表和旧的筛选项都要清掉（不然会把上个站点的筛选条件发给新站点）
            items = []
            selected = [:]
        }
        loadTask = Task { await loadSiteBody(token: token, keepItems: keepItems) }
        scheduleSlowHint(token: token)
    }

    /// 用户等不下去时可以按"取消"（尤其是没预热到的站点，第一次要等它解析上游地址）
    private func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        loadToken += 1
        loading = false
        slowHint = false
        CatyLog.shared.info("site", "用户取消了这次载入")
    }

    @MainActor
    private func scheduleSlowHint(token: Int) {
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard token == loadToken, loading else { return }
            slowHint = true
        }
    }

    @MainActor
    private func loadSiteBody(token: Int, keepItems: Bool) async {
        guard let site = currentSite, let client = coordinator.client else {
            if token == loadToken { loading = false }
            return
        }
        let previousItems = items
        do {
            if let cached = siteMenus[site.id] {
                // 这个站点问过一次了：分类/筛选项直接用缓存，只发一个 category 请求
                guard token == loadToken else { return }
                categories = cached.categories
                categoryFilters = cached.filters
            } else {
                let home = try await client.home(site: site)
                guard token == loadToken else { return }
                categories = home.categories
                categoryFilters = home.filters
                siteMenus[site.id] = SiteMenus(categories: home.categories, filters: home.filters)
                CatyLog.shared.info("site", "\(site.name)：\(home.categories.count) 个分类（已缓存）")
            }
            tid = categories.first?.id
            page = 1
            pageCount = 1
            if let first = tid {
                let result = try await client.category(site: site, tid: first, page: 1)
                guard token == loadToken else { return }
                items = result.items
                page = result.page
                pageCount = result.pageCount
            } else {
                items = []
            }
            if items.isEmpty { errorText = "这个站点没有返回内容" }
        } catch {
            guard token == loadToken else { return }
            if keepItems { items = previousItems }
            errorText = error.localizedDescription
            CatyLog.shared.warn("site", "\(site.name) 载入失败：\(error.localizedDescription)")
        }
        if token == loadToken {
            loading = false
            slowHint = false
        }
    }

    @MainActor
    private func loadMore() async {
        guard let site = currentSite, let client = coordinator.client,
              !loading, page < pageCount, items.count > 1 else { return }
        let token = loadToken
        do {
            let result = try await client.category(site: site, tid: tid, page: page + 1, extend: selected)
            guard token == loadToken else { return }
            let existing = Set(items.map(\.id))
            items.append(contentsOf: result.items.filter { !existing.contains($0.id) })
            page = result.page
            pageCount = result.pageCount
        } catch {
            CatyLog.shared.warn("site", "加载下一页失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 源列表（2 列 + 按源分组）

/// 每个源实测有几十个站点，原来的下拉菜单一行一个、只能看半截名字；
/// 改成弹窗里 2 列铺开，并按"来自哪个源"分组（多源同时跑时这是必需的）。
private struct SourcePickerSheet: View {

    struct Group: Identifiable {
        let id: String
        let name: String
        let sites: [SiteInfo]
    }

    let groups: [Group]
    let currentId: String?
    let onPick: (SiteInfo) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: Theme.spacingM),
        GridItem(.flexible(), spacing: Theme.spacingM)
    ]

    private var total: Int { groups.reduce(0) { $0 + $1.sites.count } }

    var body: some View {
        NavigationStack {
            ScrollView {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: Theme.spacingS) {
                        HStack(spacing: 6) {
                            Text(group.name).font(.subheadline).fontWeight(.semibold)
                            Text("\(group.sites.count) 个站点")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: columns, spacing: Theme.spacingM) {
                            ForEach(group.sites) { site in
                                Button {
                                    onPick(site)
                                    dismiss()
                                } label: {
                                    cell(site)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.bottom, Theme.spacingM)
                }
                .padding(Theme.padding)
            }
            .navigationTitle("选择站点（\(total)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func cell(_ site: SiteInfo) -> some View {
        let isOn = site.id == currentId
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


/// 一个站点问过一次的"分类 + 筛选项"（换源时少一次往返，切换更快）
private struct SiteMenus {
    var categories: [Category]
    var filters: [String: [FilterGroup]]
}
