//
//  BrowseView.swift
//  某个站点的内容列表（P4 粗版）：分类切换 + 翻页
//

import SwiftUI

struct BrowseView: View {

    let site: SiteInfo
    let client: NodeClient?

    @State private var categories: [Category] = []
    @State private var selectedTid: String?
    @State private var items: [VodItem] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        List {
            if !categories.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip("全部", isSelected: selectedTid == nil) {
                                selectedTid = nil
                                Task { await reload() }
                            }
                            ForEach(categories) { category in
                                chip(category.name, isSelected: selectedTid == category.id) {
                                    selectedTid = category.id
                                    Task { await reload() }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            ForEach(items) { item in
                NavigationLink(value: item) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.body).lineLimit(2)
                            if let remarks = item.remarks {
                                Text(remarks).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if let year = item.year {
                            Text(year).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .onAppear {
                    if item.id == items.last?.id {
                        Task { await loadMore() }
                    }
                }
            }

            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
            if items.isEmpty && !loading && errorText == nil {
                Text("（这个分类没有内容）").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(site.name)
        .navigationDestination(for: VodItem.self) { item in
            DetailView(item: item, site: site, client: client)
        }
        .task { await reload() }
    }

    private func chip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 取数

    @MainActor
    private func reload() async {
        page = 1
        items = []
        pageCount = 1
        await fetch(reset: true)
    }

    @MainActor
    private func loadMore() async {
        guard !loading, page < pageCount else { return }
        await fetch(reset: false)
    }

    @MainActor
    private func fetch(reset: Bool) async {
        guard let client, !loading else {
            if client == nil { errorText = "运行时还没就绪" }
            return
        }
        loading = true
        defer { loading = false }
        do {
            let result = try await client.category(site: site, tid: selectedTid, page: reset ? 1 : page + 1)
            if reset {
                items = result.items
            } else {
                items.append(contentsOf: result.items)
            }
            page = result.page
            pageCount = result.pageCount
            if categories.isEmpty, !result.categories.isEmpty {
                categories = result.categories
            }
            errorText = nil
        } catch {
            errorText = "取不到内容：\(error.localizedDescription)"
            CatyLog.shared.warn("site", "分类内容失败：\(error.localizedDescription)")
        }
    }
}
