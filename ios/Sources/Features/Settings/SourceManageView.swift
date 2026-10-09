//
//  SourceManageView.swift
//  源管理：导入订阅地址 / 看清单 / **即时启停** / 删除
//
//  2026-10-10 起：开关是**即时生效**的（不再"改了要重启 App"）——
//  已经在跑的源之间切换本来就是秒切（所有已开启的源一起跑，首页站点列表是并集）；
//  新开一个源走运行时的控制口（/ctl/source）现场启动，也不用重启。
//

import SwiftUI
import UIKit

struct SourceManageView: View {

    @ObservedObject var coordinator: RuntimeCoordinator
    /// 嵌进「设置」里时不要再套一层 NavigationStack
    var embedded = false

    @State private var input = ""
    @State private var errorText: String?
    @State private var busy = false
    @State private var panelHint: String?
    /// 正在改名的源（用户要求：源管理里能改标题）
    @State private var renaming: SourceRecord?
    @State private var newName = ""

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
        List {
            statusSection
            panelSection
            importSection
            listSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Caty · 源")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { coordinator.refreshRecords() }
        .alert("改标题", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("给这个源起个名字", text: $newName)
            Button("保存") {
                if let record = renaming {
                    coordinator.renameSource(record.id, to: newName)
                }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        } message: {
            Text("只改显示的名字，不影响源本身。")
        }
    }

    // MARK: - 源配置中心（登录网盘）

    private var panelSection: some View {
        Section("源配置中心") {
            Button {
                if !coordinator.runtime.openWebPanel() {
                    panelHint = "运行时就绪后才能打开（先看「诊断」页）"
                } else {
                    panelHint = nil
                }
            } label: {
                Label("打开配置中心（登录夸克/百度等网盘）", systemImage: "safari")
            }
            .disabled(coordinator.runtime.serviceBase == nil)

            if let panelHint {
                Text(panelHint).font(.footnote).foregroundStyle(.orange)
            }
            Text("网盘源必须先在配置中心登录对应网盘，播放时才拿得到直链。源自己也会在需要时弹这个面板。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 激活状态

    private var statusSection: some View {
        Section("激活状态") {
            HStack(spacing: 8) {
                Circle().fill(phaseColor).frame(width: 12, height: 12)
                Text(coordinator.phase.label).font(.headline)
                Spacer()
                if coordinator.runningSourceIds.count > 1 {
                    Text("\(coordinator.runningSourceIds.count) 个源同时在跑")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let name = coordinator.activeSourceName {
                    Text(name).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let md5 = coordinator.activeBundleMD5 {
                Text("bundle \(md5)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            if let message = coordinator.lastMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Text("开关即时生效：已开启的源会**同时运行**，在首页左上角随时切换，不用重启 App。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var phaseColor: Color {
        switch coordinator.phase {
        case .ready: return .green
        case .failed, .unsupported: return .red
        case .idle: return .gray
        default: return .orange
        }
    }

    // MARK: - 导入

    private var importSection: some View {
        Section("导入源") {
            TextField("http://user:pass@host/index.js.md5", text: $input)
                .font(.system(size: 12, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            HStack {
                Button("从剪贴板粘贴") {
                    if let text = UIPasteboard.general.string { input = text }
                }
                Spacer()
                Button(busy ? "导入中…" : "导入") {
                    Task { await doImport() }
                }
                .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }

            Text("导入时会立刻下载并做 MD5 校验；地址里的账号密码只进 Keychain，不写进文件。导入完点它的开关即可使用。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func doImport() async {
        busy = true
        errorText = nil
        let result = await coordinator.importSource(input)
        errorText = result
        if result == nil { input = "" }
        busy = false
    }

    // MARK: - 清单

    private var listSection: some View {
        Section("已导入（\(coordinator.records.count)）") {
            if coordinator.records.isEmpty {
                Text("还没有源。有 Mac 之前可以先跑打桩源自检（诊断页）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(coordinator.records) { record in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(record.displayName).font(.headline)
                        Button {
                            newName = record.displayName
                            renaming = record
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.borderless)
                        runningBadge(record)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { record.enabled },
                            set: { value in Task { await coordinator.setSourceEnabled(record.id, value) } }
                        ))
                        .labelsHidden()
                    }
                    Text(record.url)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("bundle \(record.shortMD5)   契约 \(record.lastContractKind ?? "—")"
                        + (record.mirrors.isEmpty ? "" : "   镜像 \(record.mirrors.count) 个"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let note = coordinator.sourceNotes[record.id], record.enabled {
                        Text(note).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let error = record.lastError {
                        Text(error).font(.caption2).foregroundStyle(.red)
                        Button {
                            Task { await coordinator.retrySource(record.id) }
                        } label: {
                            Label("重试取包", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .swipeActions {
                    Button {
                        newName = record.displayName
                        renaming = record
                    } label: {
                        Label("改标题", systemImage: "pencil")
                    }
                    .tint(Theme.accent)

                    Button("删除", role: .destructive) { coordinator.delete(id: record.id) }
                }
            }
        }
    }

    @ViewBuilder
    private func runningBadge(_ record: SourceRecord) -> some View {
        if coordinator.runningSourceIds.contains(record.id) {
            Text("运行中")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.18))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        }
    }
}
