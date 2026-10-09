//
//  PlayUrlParser.swift
//  播放串解析：`$$$` 分播放源、`#` 分集、`$` 分「集名/地址」
//
//  规格来源：docs/00-protocol-spec.md §3.3
//  该 bundle 有把 `$ # @ | : & = ?` 转成全角的编码函数（用于把 JSON 塞进 URL 参数），
//  所以解析前要先**反向兼容**回来。
//

import Foundation

enum PlayUrlParser {

    /// 全角 → 半角（只处理文档实测到的那几个符号）
    private static let fullWidthToHalf: [Character: Character] = [
        "＄": "$", "＃": "#", "＠": "@", "｜": "|", "：": ":",
        "＆": "&", "＝": "=", "？": "?", "／": "/", "％": "%",
    ]

    static func normalize(_ text: String) -> String {
        String(text.map { fullWidthToHalf[$0] ?? $0 })
    }

    struct Parsed {
        var sourceNames: [String]
        var episodesBySource: [[Episode]]
    }

    static func parse(playFrom: String?, playUrl: String?) -> Parsed {
        let fromText = normalize(playFrom ?? "")
        let urlText = normalize(playUrl ?? "")

        let names = fromText
            .components(separatedBy: "$$$")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let groups = urlText.isEmpty ? [] : urlText.components(separatedBy: "$$$")
        var result: [[Episode]] = []

        for group in groups {
            var episodes: [Episode] = []
            for entry in group.components(separatedBy: "#") {
                let trimmed = entry.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if let separator = trimmed.firstIndex(of: "$") {
                    let name = String(trimmed[trimmed.startIndex..<separator])
                    let url = String(trimmed[trimmed.index(after: separator)...])
                    episodes.append(Episode(name: name.isEmpty ? "正片" : name, url: url))
                } else {
                    episodes.append(Episode(name: "正片", url: trimmed))
                }
            }
            result.append(episodes)
        }

        return Parsed(sourceNames: names, episodesBySource: result)
    }
}
