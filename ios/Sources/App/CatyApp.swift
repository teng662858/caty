//
//  CatyApp.swift
//  App 入口
//
//  界面本体在 RootView（3 个 tab + 源主动要求的 toast / 内置网页）。
//  P5 会按 docs/02-ui-spec.md 换成 5 个 tab（首页/分类/搜索/片库/设置）。
//
//  启动顺序：RuntimeCoordinator.start()
//    → 挨个试已启用的源：取包（下载/校验/缓存）→ 成功就启动它
//    → 都没有 → 启动打桩 bundle（有假数据，可直接试播）
//    → serverStarted 后自动拉 /config → 首页出现站点
//

import SwiftUI

@main
struct CatyApp: App {

    @StateObject private var coordinator = RuntimeCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator, runtime: coordinator.runtime)
                .onAppear {
                    CatyLog.shared.info("app", "Caty 启动")
                    Task { await coordinator.start() }
                }
        }
    }
}
