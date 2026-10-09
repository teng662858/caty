//
//  SourceManageView.swift
//  源管理（P3 临时版）：导入订阅地址 / 看清单 / 启停 / 删除
//
//  P5 会按 docs/02-ui-spec.md 重做（含二维码扫描、Web 面板入口）；
//  现在只求"能导入、能看见、能删"。
//

import SwiftUI
import UIKit

struct SourceManageView: View {

    @ObservedObject var coordinator: RuntimeCoordinator

    @State private var input = ""
    @State private var errorText: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                importSection
                listSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Caty · 源")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { coordinator.refreshRecords() }
        }
    }

    // MARK: - 激活状态

    private var statusSection: some View {
        Section("激活状态") {
            HStack(spacing: 8) {
                Circle().fill(phaseColor).frame(width: 12, height: 12)
                Text(coordinator.phase.label).font(.headline)
                Spacer()
                if let name = coordinator.activeSourceName {
                    Text(name).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let md5 = coordinator.activeBundleMD5 {
                Text("bundle \(md5)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            if let message = coordinator.lastMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Text(RuntimeCoordinator.restartHint)
                .font(.footnote)
                .foregroundStyle(.orange)
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

            Text("导入时会立刻下载并做 MD5 校验；地址里的账号密码只进 Keychain，不写进文件。")
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
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { record.enabled },
                            set: { coordinator.setEnabled(record.id, $0) }
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
                    if let error = record.lastError {
                        Text(error).font(.caption2).foregroundStyle(.red)
                    }
                }
                .swipeActions {
                    Button("删除", role: .destructive) { coordinator.delete(id: record.id) }
                }
            }
        }
    }
}
