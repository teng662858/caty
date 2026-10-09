//
//  VodModels.swift
//  TVBox / CatVod 数据模型（P4）
//
//  规格来源：docs/05-data-model.md §1
//
//  ⚠️ 有意与文档的一处差异：文档写的是 `Codable`，这里先用
//  `init?(json: [String: Any])` 手写解析 —— 因为源返回的字段类型会变
//  （`1` / `"1"` / `true` 都出现过），文档自己去也要求"宽松解析、不要用非可选类型"。
//  Codable 等到 P5 落库（GRDB）时再补，那时需要的是显式的行映射。
//

import Foundation

// MARK: - 宽松 JSON 读取

extension Dictionary where Key == String, Value == Any {

    func str(_ key: String) -> String? {
        guard let value = self[key], !(value is NSNull) else { return nil }
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    func int(_ key: String) -> Int? {
        guard let value = self[key], !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String {
            if let direct = Int(text) { return direct }
            if let double = Double(text) { return Int(double) }
        }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        guard let value = self[key], !(value is NSNull) else { return nil }
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.intValue != 0 }
        if let text = value as? String {
            let lowered = text.lowercased()
            return !(lowered == "0" || lowered == "false" || lowered.isEmpty)
        }
        return nil
    }

    func dict(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func dictArray(_ key: String) -> [[String: Any]] {
        (self[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    func strArray(_ key: String) -> [String] {
        (self[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }
}

// MARK: - 站点

struct SiteInfo: Identifiable, Hashable {
    var key: String
    var name: String
    var type: Int
    var api: String          // 形如 "node:/spider/<key>/<type>"
    var searchable: Bool
    var enabled: Bool
    var group: String?
    var ext: String?
    var sourceId: String

    var id: String { "\(sourceId)|\(key)" }
}

// MARK: - 条目 / 详情 / 剧集

struct VodItem: Identifiable, Hashable {
    var id: String
    var name: String
    var pic: String?
    var remarks: String?
    var tag: String?
    var typeName: String?
    var year: String?
    var siteKey: String
    var sourceId: String

    var isFolder: Bool { tag == "folder" }

    /// 显式构造（收藏/历史里存的镜像条目要还原成 VodItem 用）
    init(id: String, name: String, pic: String?, remarks: String?, tag: String?,
         typeName: String?, year: String?, siteKey: String, sourceId: String) {
        self.id = id
        self.name = name
        self.pic = pic
        self.remarks = remarks
        self.tag = tag
        self.typeName = typeName
        self.year = year
        self.siteKey = siteKey
        self.sourceId = sourceId
    }

    init?(json: [String: Any], siteKey: String, sourceId: String) {
        guard let id = json.str("vod_id"), let name = json.str("vod_name") else { return nil }
        self.id = id
        self.name = name
        self.pic = json.str("vod_pic")
        self.remarks = json.str("vod_remarks")
        self.tag = json.str("vod_tag")
        self.typeName = json.str("type_name")
        self.year = json.str("vod_year")
        self.siteKey = siteKey
        self.sourceId = sourceId
    }
}

struct Episode: Identifiable, Hashable {
    var name: String
    var url: String

    var id: String { "\(name)|\(url)" }
}

struct VodDetail {
    var item: VodItem
    var content: String?
    var actor: String?
    var director: String?
    var area: String?
    var playFrom: [String]
    var episodes: [[Episode]]

    /// 播放源名（按 $$$ 拆），数量不足时补「线路 N」
    func sourceName(at index: Int) -> String {
        index < playFrom.count ? playFrom[index] : "线路 \(index + 1)"
    }
}

// MARK: - 分类页

struct Category: Identifiable, Hashable {
    var id: String
    var name: String
}

struct CategoryPage {
    var categories: [Category]
    var items: [VodItem]
    var page: Int
    var pageCount: Int
}
