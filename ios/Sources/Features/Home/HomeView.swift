//
//  HomeView.swift
//  首页（P4 粗版）：列出源返回的站点 → 点进去看内容
//
//  P5 会按 docs/02-ui-spec.md 换成海报网格 + 骨架屏；现在只求"能点进去、能播"。
//

import SwiftUI

struct HomeView: View {

    @ObservedObject var coordinator: RuntimeCoordinator

    var body: some View {
        NavigationStack {
            List {
                if coordinator.sites.isEmpty {
                    Section {
                        Text(coordinator.runtime.state == .ready
                             ? "这个源没有返回站点目录（去「诊断」tab 看日志里的 /config 响应）"
                             : "等运行时就绪…（去「诊断」tab 看进度）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("站点（\(coordinator.sites.count)）") {
                        ForEach(coordinator.sites) { site in
                            NavigationLink(value: site) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(site.name).font(.headline)
                                    Text(site.api)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("运行时") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(coordinator.runtime.state == .ready ? Color.green : Color.orange)
                            .frame(width: 10, height: 10)
                        Text(coordinator.runtime.state.label).font(.footnote)
                        Spacer()
                        if let name = coordinator.activeSourceName {
                            Text(name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let message = coordinator.lastMessage {
                        Text(message).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Caty")
            .navigationDestination(for: SiteInfo.self) { site in
                BrowseView(site: site, client: coordinator.client)
            }
            .toolbar {
                Button {
                    Task { await coordinator.loadSites() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }
}
