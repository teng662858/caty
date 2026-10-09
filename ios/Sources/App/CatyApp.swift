//
//  CatyApp.swift
//  App 入口
//
//  界面本体在 RootView（4 个 tab + 源主动要求的 toast / 内置网页）。
//
//  启动顺序：RuntimeCoordinator.start()
//    → 取包（下载/校验/缓存）→ 启动**所有已启用的源**（一个 Node 进程跑多个 bundle）
//    → 都没有 → 启动打桩 bundle（有假数据，可直接试播）
//    → 每个源一就绪就拉它的 /config → 首页出现站点（并集，按源分组）
//
//  方向控制：App 平时**锁竖屏**；只有播放页进全屏时才允许横屏（见 ScreenOrientation）。
//

import SwiftUI
import UIKit

/// 允许的方向（Info.plist 里已声明横竖屏，这里再按状态收窄：平时只给竖屏）
final class OrientationLock {
    static let shared = OrientationLock()
    var mask: UIInterfaceOrientationMask = .portrait
}

@main
struct CatyApp: App {

    @UIApplicationDelegateAdaptor(CatyAppDelegate.self) private var appDelegate
    @StateObject private var coordinator = RuntimeCoordinator()

    init() {
        // 图片缓存：磁盘 500 MB / 内存 50 MB（docs/05 §2 的规格）
        URLCache.shared = URLCache(memoryCapacity: 50 * 1024 * 1024,
                                   diskCapacity: 500 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator, runtime: coordinator.runtime)
                .onAppear {
                    CatyLog.shared.info("app", "Caty 启动")
                    MPVProbe.logVersion()
                    Task { await coordinator.start() }
                }
        }
    }
}

final class CatyAppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.shared.mask
    }
}

/// 切方向：iOS 16 起用 requestGeometryUpdate（比老办法干净，不需要私有 API）
enum ScreenOrientation {

    static func lockPortrait() {
        apply(.portrait)
    }

    static func lockLandscape() {
        apply(.landscape)
    }

    private static func apply(_ mask: UIInterfaceOrientationMask) {
        OrientationLock.shared.mask = mask
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        // ⚠️ 顺序很重要（真机日志里踩过）：
        //   1) 先改"允许的方向"，并让**最上层**的 VC 重新问一次 delegate
        //      （只对 rootViewController 调是不够的：全屏弹出时顶层是那个 cover 的 VC）
        //   2) 等一个 runloop 再 requestGeometryUpdate —— 否则会报
        //      "所有已请求的方向均不受视图控制器支持"（日志里刷了一屏）
        let controller = topViewController(from: scene.keyWindow?.rootViewController
                                           ?? scene.windows.first?.rootViewController)
        controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
        let label = (mask == .portrait) ? "竖屏" : "横屏"
        DispatchQueue.main.async {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                CatyLog.shared.warn("ui", "切方向失败（\(label)）：\(error.localizedDescription)")
            }
            controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    /// 递归找最上层（presented）的视图控制器
    private static func topViewController(from base: UIViewController?) -> UIViewController? {
        guard let base else { return nil }
        if let presented = base.presentedViewController { return topViewController(from: presented) }
        if let navigation = base as? UINavigationController { return topViewController(from: navigation.visibleViewController) }
        if let tab = base as? UITabBarController { return topViewController(from: tab.selectedViewController) }
        return base
    }
}
