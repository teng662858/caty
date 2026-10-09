//
//  DiagnosticsView.swift
//  P2 自检屏（临时版）：一眼看出「Node 起来了没 / 桥通了没 / 能不能读到站点目录」
//
//  P5 会按 docs/02-ui-spec.md 重做这张屏；现在只求能验收、能贴报错。
//

import SwiftUI
import UIKit

struct DiagnosticsView: View {

    @ObservedObject var runtime: NodeRuntime

    @State private var refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var logLines: [String] = []
    @State private var healthText = "（点下面的「自检」按钮）"
    @State private var configText = "（点下面的「读站点目录」按钮）"
    @State private var hint: String?

    var body: some View {
        NavigationStack {
            List {
                statusSection
                numbersSection
                selfCheckSection
                logSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Caty · P2 自检")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { refreshLog() }
            .onReceive(refreshTimer) { _ in refreshLog() }
        }
    }

    // MARK: - 状态

    private var statusSection: some View {
        Section("状态") {
            HStack(spacing: 8) {
                Circle().fill(stateColor).frame(width: 12, height: 12)
                Text(runtime.state.label).font(.headline)
                Spacer()
                if let seconds = runtime.startupSeconds {
                    Text(String(format: "启动 %.2fs", seconds))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = runtime.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if runtime.state == .failed || runtime.state == .exited {
                Text("iOS 上一个进程只能启动一次 Node（node_start 不可重入）：杀掉 App 重新打开，就会重跑一遍。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var stateColor: Color {
        switch runtime.state {
        case .ready: return .green
        case .failed, .exited: return .red
        case .idle: return .gray
        default: return .orange
        }
    }

    // MARK: - 关键数字

    private var numbersSection: some View {
        Section("运行时") {
            keyValue("bridge 端口", runtime.bridgePort == 0 ? nil : String(runtime.bridgePort))
            keyValue("服务地址", runtime.serviceBase)
            keyValue("Node 版本", runtime.nodeVersion)
            keyValue("架构 / pid", runtime.nodeArch.map { "\($0) / \(runtime.nodePid.map(String.init) ?? "-")" })
            keyValue("编译缓存", runtime.compileCachePath)
            keyValue("数据目录", runtime.dataRootPath)
            keyValue("bootstrap", runtime.bootstrapPath)
        }
    }

    private func keyValue(_ key: String, _ value: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 自检

    private var selfCheckSection: some View {
        Section("自检") {
            Button {
                Task { healthText = await runtime.probe("/health") }
            } label: {
                Label("自检：GET /health", systemImage: "waveform.path.ecg")
            }

            Text(healthText)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)

            Button {
                Task { configText = await runtime.probe("/config") }
            } label: {
                Label("读站点目录：GET /config", systemImage: "list.bullet.rectangle")
            }

            Text(configText)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)

            Button { copyLog() } label: {
                Label("复制日志（已脱敏）", systemImage: "doc.on.doc")
            }

            if let hint {
                Text(hint).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        Section("日志（最近 \(logLines.count) 行，已脱敏）") {
            if logLines.isEmpty {
                Text("（还没有日志）").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func refreshLog() {
        logLines = CatyLog.shared.snapshot(last: 60).map(\.display)
    }

    private func copyLog() {
        UIPasteboard.general.string = CatyLog.shared.exportText(header: exportHeader())
        hint = "已复制到剪贴板（开头带环境头，内容已脱敏）"
    }

    private func exportHeader() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var lines: [String] = []
        lines.append("=== Caty 日志导出 ===")
        lines.append("App \(version) (\(build))   iOS \(UIDevice.current.systemVersion)")
        lines.append("运行时 \(runtime.state.rawValue)  bridge=\(runtime.bridgePort)  node=\(runtime.nodeVersion ?? "?")  pid=\(runtime.nodePid.map(String.init) ?? "?")")
        lines.append("服务地址 \(runtime.serviceBase ?? "-")")
        lines.append("编译缓存 \(runtime.compileCachePath ?? "-")")
        lines.append("数据目录 \(runtime.dataRootPath ?? "-")")
        lines.append("=====================")
        return lines.joined(separator: "\n")
    }
}
