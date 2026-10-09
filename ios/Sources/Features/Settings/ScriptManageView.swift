//
//  ScriptManageView.swift
//  站点脚本管理（P6+）
//
//  给用户看的一句话：**有些站点（「直」xxx / 「盘」xxx）本身没有内建实现，
//  要靠一个 JS 脚本才能打开**——猫爪那类 App 自带或能订阅这些脚本，我们这里让你自己导入。
//
//  脚本放哪儿：见 ScriptStore 的注释（catpaw 系看 ~/Library/Application Support/CatPaw/js，
//  另一支看 CATPAW_CUSTOM_SPIDER_DIR，我们两边都写一份）。装完**重启 App** 才生效
//  （bundle 只在启动时 require 脚本）。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ScriptManageView: View {

    @ObservedObject var coordinator: RuntimeCoordinator

    @State private var subscription = ""
    @State private var sourceId: String?
    @State private var scripts: [ScriptStore.Script] = []
    @State private var busy = false
    @State private var message: String?
    @State private var errorText: String?
    @State private var importing = false

    private var enabledSources: [SourceRecord] {
        let enabled = coordinator.records.filter { $0.enabled }
        return enabled.isEmpty ? coordinator.records : enabled
    }

    var body: some View {
        List {
            Section("这是什么") {
                Text("有些站点的「直」xxx / 「盘」xxx 没有内建实现，要靠一个 JS 脚本才能打开"
                     + "（脚本目录里没有对应脚本时，源会报 Dynamic spider handler not found）。"
                     + "猫爪那类 App 自带这些脚本；这里可以自己订阅或导入。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("脚本订阅（.cjs.md5 / .js.md5 / .js）") {
                TextField("https://…/xxx.cjs.md5", text: $subscription)
                    .font(.system(size: 12, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                HStack {
                    Button("从剪贴板粘贴") {
                        if let text = UIPasteboard.general.string { subscription = text }
                    }
                    Spacer()
                    Button(busy ? "下载中…" : "下载并安装") {
                        Task { await installFromSubscription() }
                    }
                    .disabled(busy || subscription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Button {
                    importing = true
                } label: {
                    Label("从文件导入（.js / .cjs）", systemImage: "doc.badge.plus")
                }

                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.green)
                }
                Text("装完要**重启 App** 才生效（源只在启动时加载脚本）。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Section("装到哪个源（多源时选一个）") {
                Picker("源", selection: Binding(
                    get: { sourceId ?? enabledSources.first?.id ?? "" },
                    set: { sourceId = $0 }
                )) {
                    ForEach(enabledSources) { record in
                        Text(record.displayName).tag(record.id)
                    }
                }
            }

            Section("已安装（\(scripts.count)）") {
                if scripts.isEmpty {
                    Text("还没有脚本。没脚本时「直」/「盘」这类站点是打不开的（源自己会说 Dynamic spider handler not found）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(scripts) { script in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(script.name).font(.subheadline)
                        Text("\(script.bytes / 1024) KB · \(script.path)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            ScriptStore.shared.remove(script)
                            reload()
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("站点脚本")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.data, .plainText, .item],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .onAppear { reload() }
    }

    // MARK: - 逻辑

    private func reload() {
        let id = sourceId ?? enabledSources.first?.id ?? ""
        sourceId = id
        scripts = id.isEmpty ? [] : ScriptStore.shared.installed(for: id)
    }

    private func installFromSubscription() async {
        guard let id = sourceId ?? enabledSources.first?.id else {
            errorText = "先导入一个源"
            return
        }
        busy = true
        errorText = nil
        message = nil
        do {
            let paths = try await ScriptStore.shared.install(fromSubscription: subscription, sourceId: id)
            message = "已安装到 \(paths.count) 个目录，重启 App 后用得上"
            subscription = ""
            reload()
        } catch {
            errorText = error.localizedDescription
        }
        busy = false
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard let id = sourceId ?? enabledSources.first?.id else {
            errorText = "先导入一个源"
            return
        }
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let paths = try ScriptStore.shared.install(fromFile: url, sourceId: id)
                message = "已安装到 \(paths.count) 个目录，重启 App 后用得上"
                errorText = nil
                reload()
            } catch {
                errorText = error.localizedDescription
            }
        case .failure(let error):
            errorText = error.localizedDescription
        }
    }
}
