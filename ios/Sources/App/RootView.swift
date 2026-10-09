//
//  RootView.swift
//  根视图：4 个 tab（首页 / 片库 / 搜索 / 设置）+ 源主动要求的两个交互（toast / 内置网页）
//
//  为什么需要这一层：真源实测会通过 /msg 桥主动推两种消息——
//    · action=toast                → 它想给用户看的提示（例如「还没有配置夸克 Cookie…」）
//    · action=openInternalWebview  → 它要求宿主打开一个内置网页（源的配置中心，用来登录网盘）
//

import SwiftUI
import WebKit

struct RootView: View {

    @ObservedObject var coordinator: RuntimeCoordinator
    @ObservedObject var runtime: NodeRuntime

    @State private var toastVisible = false

    var body: some View {
        TabView {
            HomeView(coordinator: coordinator)
                .tabItem { Label("首页", systemImage: "house") }

            LibraryView(coordinator: coordinator)
                .tabItem { Label("片库", systemImage: "books.vertical") }

            SearchView(coordinator: coordinator)
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }

            SettingsView(coordinator: coordinator)
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .sheet(isPresented: Binding(
            get: { runtime.webPanelURL != nil },
            set: { if !$0 { runtime.closeWebPanel() } }
        )) {
            if let url = runtime.webPanelURL {
                NavigationStack {
                    WebPanelView(url: url)
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle("源 · 配置中心")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("完成") { runtime.closeWebPanel() }
                            }
                        }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if toastVisible, let text = runtime.toastText {
                Text(text)
                    .font(.footnote)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 84)
                    .transition(.opacity)
                    .onTapGesture { runtime.clearToast() }
            }
        }
        .onChange(of: runtime.toastText) { _, newValue in
            guard newValue != nil else {
                toastVisible = false
                return
            }
            withAnimation { toastVisible = true }
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                withAnimation { toastVisible = false }
                runtime.clearToast()
            }
        }
    }
}

/// 极简内置浏览器（源的配置中心是网页，登录网盘也在里面完成）
struct WebPanelView: UIViewRepresentable {

    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        CatyLog.shared.info("ui", "打开内置网页：\(url.absoluteString)")
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
