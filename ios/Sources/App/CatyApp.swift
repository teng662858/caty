//
//  CatyApp.swift
//  App 入口
//
//  P4 版本：三个 tab（首页 / 源 / 诊断）。
//  P5 会换成 docs/02-ui-spec.md 里的 5 个 tab（首页/分类/搜索/片库/设置）。
//
//  启动顺序：RuntimeCoordinator.start()
//    → 有已启用源：取包（下载/校验/缓存）→ 启动该源
//    → 没有源    ：启动打桩 bundle（有假数据，可以直接试播）
//    → 运行时 serverStarted 后自动拉 /config → 首页出现站点
//

import SwiftUI

@main
struct CatyApp: App {

    @StateObject private var coordinator = RuntimeCoordinator()

    var body: some Scene {
        WindowGroup {
            TabView {
                HomeView(coordinator: coordinator)
                    .tabItem { Label("首页", systemImage: "house") }

                SourceManageView(coordinator: coordinator)
                    .tabItem { Label("源", systemImage: "square.stack.3d.up") }

                DiagnosticsView(runtime: coordinator.runtime)
                    .tabItem { Label("诊断", systemImage: "waveform.path.ecg") }
            }
            .onAppear {
                CatyLog.shared.info("app", "Caty 启动")
                Task { await coordinator.start() }
            }
        }
    }
}
