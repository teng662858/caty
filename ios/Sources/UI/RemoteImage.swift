//
//  RemoteImage.swift
//  封面图加载（替掉 SwiftUI 的 AsyncImage）
//
//  为什么要自己写：
//   · AsyncImage 用的是 URLSession.shared，**不能带自定义请求头** ——
//     百度/豆瓣那些图床对 Referer 很敏感，不带就是空白（用户反馈"有些站点没封面"的一个原因）
//   · 它没有内存缓存：列表滚动会反复重下、闪一下
//   · 失败时我们要显示"文字封面"而不是灰图标
//
//  做法：URLSession（带 URLCache，App 启动时配了 500MB 磁盘）+ NSCache 内存缓存 + 失败兜底。
//
//  2026-10-11：源的 /imageProxy 拆开来自己直连（见 directTarget）。
//  封面全都绕源的代理时，一屏几十张图会全挤在源那**一个 Node 线程**上（iOS 没有 JIT），
//  用户在首页切换站点要等的 home/category 只能排在它们后面 —— 表现就是"切换源直接卡死"。
//  源在代理参数里已经把该带的东西给了我们（url + customHeaders 里的 Referer/UA），
//  直连失败再回退到代理，行为不变但省掉了源的负担。
//

import SwiftUI
import UIKit

final class RemoteImageLoader {

    static let shared = RemoteImageLoader()

    private let session: URLSession
    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache.shared
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
        memory.countLimit = 400
    }

    func cached(_ urlString: String) -> UIImage? {
        memory.object(forKey: urlString as NSString)
    }

    func image(for urlString: String) async -> UIImage? {
        if let hit = cached(urlString) { return hit }

        lock.lock()
        if let existing = inFlight[urlString] {
            lock.unlock()
            return await existing.value
        }
        let task = Task<UIImage?, Never> { [session] in
            await RemoteImageLoader.fetch(urlString, session: session)
        }
        inFlight[urlString] = task
        lock.unlock()

        let image = await task.value
        lock.lock()
        inFlight[urlString] = nil
        lock.unlock()
        if let image { memory.setObject(image, forKey: urlString as NSString) }
        return image
    }

    // MARK: - 取图

    private static func fetch(_ urlString: String, session: URLSession) async -> UIImage? {
        // 源的图片代理：能直连就直连
        if let direct = directTarget(for: urlString) {
            if let image = await download(direct.url, headers: direct.headers, session: session) {
                return image
            }
        }
        guard let url = URL(string: urlString) else { return nil }
        return await download(url, headers: [:], session: session)
    }

    /// 把 `<源地址>/imageProxy?url=…&customHeaders={…}` 拆成"真地址 + 请求头"；
    /// 不是图片代理（或拆不出来）返回 nil
    static func directTarget(for urlString: String) -> (url: URL, headers: [String: String])? {
        guard let components = URLComponents(string: urlString),
              components.path.hasSuffix("/imageProxy"),
              let items = components.queryItems else { return nil }
        let inner = items.first { $0.name == "url" }?.value ?? ""
        guard inner.hasPrefix("http://") || inner.hasPrefix("https://"),
              let url = URL(string: inner) else { return nil }

        var headers: [String: String] = [:]
        if let raw = items.first(where: { $0.name == "customHeaders" })?.value,
           let data = raw.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (key, value) in object {
                if let text = value as? String, !text.isEmpty { headers[key] = text }
            }
        }
        return (url, headers)
    }

    private static func download(_ url: URL, headers: [String: String],
                                 session: URLSession) async -> UIImage? {
        var request = URLRequest(url: url)
        request.setValue(headers["User-Agent"] ?? "okhttp/3.15.0", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // 图床防盗链：没给 Referer 就带图片自己域名的
        if headers["Referer"] == nil, let scheme = url.scheme, let host = url.host {
            request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code), let image = UIImage(data: data) else {
                CatyLog.shared.debug("ui", "封面加载失败 HTTP \(code)：\(url.host ?? "")")
                return nil
            }
            return image
        } catch {
            CatyLog.shared.debug("ui", "封面加载异常：\(error.localizedDescription)")
            return nil
        }
    }
}

/// 异步封面：先查内存缓存（有就直接显示，不闪），没有就下载
struct RemoteImage: View {

    let urlString: String?
    var fallbackText: String?

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                textFallback
            } else {
                Image(systemName: "ellipsis")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: urlString) { await load() }
    }

    @ViewBuilder
    private var textFallback: some View {
        if let text = fallbackText, !text.isEmpty {
            // 没有封面就用"文字封面"：比灰图标好认（有些站点源里就没有封面图）
            Text(String(text.prefix(4)))
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(6)
                .foregroundStyle(Theme.accent.opacity(0.85))
        } else {
            Image(systemName: "film")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        guard let urlString, !urlString.isEmpty else {
            failed = true
            return
        }
        if let hit = RemoteImageLoader.shared.cached(urlString) {
            image = hit
            failed = false
            return
        }
        failed = false
        let loaded = await RemoteImageLoader.shared.image(for: urlString)
        // 视图已经走了（切站点/换屏）就别再改状态
        if Task.isCancelled { return }
        image = loaded
        failed = loaded == nil
    }
}
