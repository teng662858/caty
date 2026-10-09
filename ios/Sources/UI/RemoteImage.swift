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
            guard let url = URL(string: urlString) else { return nil }
            var request = URLRequest(url: url)
            request.setValue("okhttp/3.15.0", forHTTPHeaderField: "User-Agent")
            // 图床防盗链：带上图片自己域名的 Referer，命中率明显更高
            if let scheme = url.scheme, let host = url.host {
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
        inFlight[urlString] = task
        lock.unlock()

        let image = await task.value
        lock.lock()
        inFlight[urlString] = nil
        lock.unlock()
        if let image { memory.setObject(image, forKey: urlString as NSString) }
        return image
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
        image = loaded
        failed = loaded == nil
    }
}
