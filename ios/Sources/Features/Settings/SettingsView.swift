//
//  SettingsView.swift
//  设置：播放 / 界面 / 源 / 存储 / 关于（入口都收在这里，tab 保持精简）
//

import SwiftUI
import UIKit

struct SettingsView: View {

    @ObservedObject var coordinator: RuntimeCoordinator
    @ObservedObject private var library = LibraryStore.shared

    @State private var cacheText = "—"
    @State private var hint: String?

    private var runtime: NodeRuntime { coordinator.runtime }

    var body: some View {
        NavigationStack {
            List {
                playbackSection
                appearanceSection
                sourceSection
                storageSection
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { cacheText = library.cacheDescription }
        }
    }

    // MARK: - 播放

    private var playbackSection: some View {
        Section("播放") {
            Picker("默认倍速", selection: Binding(
                get: { library.settings.rate },
                set: { library.settings.rate = $0 }
            )) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                    Text(value == 1.0 ? "正常" : String(format: "%gx", value)).tag(value)
                }
            }
            Toggle("记忆播放进度（断点续播）", isOn: Binding(
                get: { library.settings.rememberProgress },
                set: { library.settings.rememberProgress = $0 }
            ))
        }
    }

    // MARK: - 界面

    private var appearanceSection: some View {
        Section("界面") {
            Picker("首页每行海报数", selection: Binding(
                get: { library.settings.gridColumns },
                set: { library.settings.gridColumns = $0 }
            )) {
                Text("2 个").tag(2)
                Text("3 个").tag(3)
                Text("4 个").tag(4)
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - 源

    private var sourceSection: some View {
        Section("源") {
            NavigationLink {
                SourceManageView(coordinator: coordinator, embedded: true)
            } label: {
                Label("源管理（导入 / 删除 / 重试）", systemImage: "square.stack.3d.up")
            }

            Button {
                if runtime.openWebPanel() {
                    hint = "已打开源配置中心（登录夸克/百度等网盘）"
                } else {
                    hint = "运行时就绪后才能打开"
                }
            } label: {
                Label("打开源配置中心（登录网盘）", systemImage: "safari")
            }
            .disabled(runtime.serviceBase == nil)

            NavigationLink {
                DiagnosticsView(runtime: runtime, embedded: true)
            } label: {
                Label("诊断与日志", systemImage: "waveform.path.ecg")
            }

            if let hint {
                Text(hint).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 存储

    private var storageSection: some View {
        Section("存储") {
            HStack {
                Text("图片缓存")
                Spacer()
                Text(cacheText).foregroundStyle(.secondary)
            }
            Button("清除图片缓存") {
                library.clearImageCache()
                cacheText = library.cacheDescription
                hint = "已清除图片缓存"
            }
            Button("清空观看历史", role: .destructive) { library.clearHistory() }
            Button("清空收藏", role: .destructive) { library.clearFavorites() }
            Button("清空搜索历史", role: .destructive) { SearchHistoryStore.shared.removeAll() }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section("关于") {
            keyValue("App 版本", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            keyValue("系统", UIDevice.current.systemVersion)
            keyValue("Node 运行时", runtime.nodeVersion)
            keyValue("当前源", coordinator.activeSourceName)
            keyValue("bundle", coordinator.activeBundleMD5)
            keyValue("站点数", String(coordinator.sites.count))
            Text("Caty 只是一个容器：不含任何内容源，源由你自己导入。仅供自签自用。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func keyValue(_ key: String, _ value: String?) -> some View {
        HStack {
            Text(key)
            Spacer()
            Text(value ?? "—")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}
