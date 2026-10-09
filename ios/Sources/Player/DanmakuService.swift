//
//  DanmakuService.swift
//  弹幕（P6）：从源里取弹幕并解析
//
//  契约（2026-10-10 桌面实测，A 家族）：
//    GET <源服务地址>/danmu/auto?name=<剧名>&episode=<集>  → B 站风格 XML：
//      <i><d p="时间,模式,字号,颜色,时间戳,池,用户,ID">弹幕文本</d>…</i>
//    源的 /config 里还给了 danmuSearchUrl（那是它自己的**弹幕搜索网页**，给 WebView 用的）。
//    源另外会通过 /msg 桥问宿主 "getPlayInfo"（现在播的剧名/集名），然后推 danmuPush{url} ——
//    那套我们也支持：桥那边回答播放上下文，这里收到 danmuPush 就直接用推来的地址。
//
//  为什么自己解析 XML 而不是塞进 WebView：弹幕要**跟着播放进度走**，宿主自己画才能和快进/倍速同步。
//

import Foundation

struct DanmakuComment: Identifiable, Hashable {
    let id: Int
    let time: Double        // 出现时间（秒）
    let text: String
    let color: UInt32       // 0xRRGGBB
    let mode: Int           // 1/2/3 滚动，4 底部，5 顶部
}

/// 当前播放上下文：播放页写进来，宿主回答源的 getPlayInfo 时读出去
final class PlaybackContext {

    static let shared = PlaybackContext()

    private let lock = NSLock()
    private var payload: [String: Any] = [:]

    private init() {}

    func update(title: String, episodeName: String, flag: String, fileName: String) {
        lock.lock()
        payload = ["title": title, "episodeName": episodeName, "flag": flag, "fileName": fileName]
        lock.unlock()
    }

    var current: [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return payload
    }
}

/// 当前正在用的弹幕：小窗取好，全屏/源推送都读同一份（可观察，源推来新弹幕会自动刷新）
final class DanmakuStore: ObservableObject {

    static let shared = DanmakuStore()

    @Published private(set) var comments: [DanmakuComment] = []
    /// 源通过桥推来的弹幕地址（它自己算好的剧名/集号，比我们猜的准）
    var pushedURL: String?
    /// 这份弹幕属于哪一集（切集时要丢掉旧的）
    var episodeKey: String?

    private init() {}

    var current: [DanmakuComment]? { comments.isEmpty ? nil : comments }

    func set(_ list: [DanmakuComment], episodeKey: String? = nil) {
        self.episodeKey = episodeKey ?? self.episodeKey
        comments = list
    }

    func clear(episodeKey: String?) {
        self.episodeKey = episodeKey
        comments = []
        pushedURL = nil
    }
}

enum DanmakuService {

    private static var cache: [String: [DanmakuComment]] = [:]
    private static let lock = NSLock()

    /// 取某个剧/某一集的弹幕（带缓存）。没有就返回空数组，不抛错（弹幕失败不该影响播放）。
    static func comments(base: String, name: String, episode: Int?) async -> [DanmakuComment] {
        let key = "\(base)|\(name)|\(episode.map(String.init) ?? "-")"
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        var components = URLComponents(string: serviceBase.hasSuffix("/danmu/auto") ? serviceBase : serviceBase + "/danmu/auto")
        var items: [URLQueryItem] = [URLQueryItem(name: "name", value: name)]
        if let episode { items.append(URLQueryItem(name: "episode", value: String(episode))) }
        components?.queryItems = items
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("okhttp/3.15.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else {
                CatyLog.shared.info("danmaku", "弹幕接口返回 \(code)（这个源可能没有弹幕）")
                return []
            }
            let parsed = parse(xml: data)
            CatyLog.shared.info("danmaku", "弹幕已就绪：\(parsed.count) 条（\(name) 第 \(episode.map(String.init) ?? "-") 集，\(data.count / 1024)KB）")
            lock.lock()
            cache[key] = parsed
            lock.unlock()
            return parsed
        } catch {
            CatyLog.shared.warn("danmaku", "取弹幕失败：\(error.localizedDescription)")
            return []
        }
    }

    /// 用**源推来的完整地址**取弹幕（地址里已经带好 name/episode）
    static func comments(fromURL rawURL: String) async -> [DanmakuComment] {
        guard let url = URL(string: rawURL) else { return [] }
        return await Task.detached(priority: .utility) { () -> [DanmakuComment] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 25
            request.setValue("okhttp/3.15.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard (200..<300).contains(code) else { return [] }
                return parse(xml: data)
            } catch {
                return []
            }
        }.value
    }

    /// 解析 B 站风格 XML：<d p="时间,模式,字号,颜色,…">文本</d>
    static func parse(xml data: Data) -> [DanmakuComment] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }
        var result: [DanmakuComment] = []
        result.reserveCapacity(4096)

        let pattern = /<d p="([^"]*)">([^<]*)<\/d>/
        var index = 0
        for match in text.matches(of: pattern) {
            let attributes = String(match.output.1)
            let raw = String(match.output.2)
            let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let fields = attributes.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 4, let time = Double(fields[0]) else { continue }
            let mode = Int(fields[1]) ?? 1
            let color = UInt32(fields[3]) ?? 0xFFFFFF
            index += 1
            result.append(DanmakuComment(id: index, time: time, text: body,
                                         color: color, mode: mode))
        }
        result.sort { $0.time < $1.time }
        return result
    }
}
