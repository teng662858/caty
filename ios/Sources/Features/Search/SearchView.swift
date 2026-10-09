//
//  SearchView.swift
//  搜索：跨已启用源的所有站点并发搜同一个关键词，结果按站点分组
//
//  真机实测过的行为（docs/contract-notes.md）：
//  - 有的站点整条 search 路由 404（没实现），属正常，直接跳过
//  - 单站超时/失败不能影响别的站点
//
//  ⚠️ 写法注意（踩过两次）：**别把整个界面塞进一个 body 表达式** ——
//  SwiftUI 嵌套一深，Swift 的类型检查器就会报 "unable to type-check this expression
//  in reasonable time"。所以下面把 List 内容、分节、行都拆成独立的小块。
//

import SwiftUI

struct SearchView: View {

    @ObservedObject var coordinator: RuntimeCoordinator

    @State private var keyword = ""
    @State private var hits: [AggregatorService.Hit] = []
    @State private var searching = false
    @State private var progressDone = 0
    @State private var progressTotal = 0
    @State private var history: [String] = SearchHistoryStore.shared.all()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("搜索")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $keyword, prompt: "输入片名")
                .onSubmit(of: .search) { Task { await run() } }
                .navigationDestination(for: AggregatorService.Hit.self) { hit in
                    DetailView(item: hit.item, site: hit.site, client: coordinator.client)
                }
                .toolbar { toolbarContent }
        }
    }

    // MARK: - 界面（拆成小块，避免类型检查爆炸）

    @ViewBuilder
    private var content: some View {
        List {
            if searching {
                progressSection
            }
            if hits.isEmpty {
                emptySections
            } else {
                resultSections
            }
        }
    }

    private var progressSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                Text(progressText).font(.footnote)
            }
        }
    }

    private var progressText: String {
        "已搜索 " + String(progressDone) + "/" + String(progressTotal) + " 个站点…"
    }

    @ViewBuilder
    private var emptySections: some View {
        if history.isEmpty {
            Section {
                Text(emptyHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("最近搜索") {
                ForEach(history, id: \.self) { word in
                    Button {
                        keyword = word
                        Task { await run() }
                    } label: {
                        Label(word, systemImage: "clock.arrow.circlepath")
                    }
                }
                Button("清空历史", role: .destructive) {
                    SearchHistoryStore.shared.removeAll()
                    history = []
                }
            }
        }
    }

    private var emptyHint: String {
        searching ? "正在搜索…" : "输入片名后点「搜索」。会同时搜已启用源里的所有可搜站点。"
    }

    @ViewBuilder
    private var resultSections: some View {
        ForEach(siteKeys, id: \.self) { key in
            Section(sectionTitle(key)) {
                ForEach(bySite[key] ?? []) { hit in
                    NavigationLink(value: hit) {
                        row(hit)
                    }
                }
            }
        }
    }

    private func row(_ hit: AggregatorService.Hit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hit.item.name).lineLimit(2)
            if let remarks = hit.item.remarks {
                Text(remarks)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var toolbarContent: some View {
        ToolbarItem(placement: .topBarTrailing) {
            if searching {
                ProgressView()
            } else {
                Button("搜索") { Task { await run() } }
                    .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - 分组

    private var bySite: [String: [AggregatorService.Hit]] {
        Dictionary(grouping: hits, by: { $0.site.key })
    }

    /// 命中数从多到少的站点顺序（显式写法：链式 sorted 闭包会让类型检查器爆炸）
    private var siteKeys: [String] {
        var pairs: [(key: String, count: Int)] = []
        pairs.reserveCapacity(bySite.count)
        for (key, list) in bySite {
            pairs.append((key: key, count: list.count))
        }
        pairs.sort { $0.count > $1.count }
        return pairs.map { $0.key }
    }

    private func sectionTitle(_ key: String) -> String {
        let count = bySite[key]?.count ?? 0
        return siteName(key) + "（" + String(count) + "）"
    }

    private func siteName(_ key: String) -> String {
        coordinator.sites.first { $0.key == key }?.name ?? key
    }

    // MARK: - 取数

    @MainActor
    private func run() async {
        let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !searching else { return }

        searching = true
        hits = []
        progressDone = 0
        progressTotal = AggregatorService.searchableSites(coordinator.sites).count
        defer { searching = false }

        SearchHistoryStore.shared.add(word)
        history = SearchHistoryStore.shared.all()

        let results = await AggregatorService.search(keyword: word,
                                                     sites: coordinator.sites,
                                                     client: coordinator.client,
                                                     batchSize: 6) { done, total in
            progressDone = done
            progressTotal = total
        }
        hits = results
    }
}
