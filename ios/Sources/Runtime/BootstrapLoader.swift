//
//  BootstrapLoader.swift
//  沙箱路径规划 + 把 App 内置的 bootstrap.js / 打桩源落到沙箱
//
//  规格来源：docs/03-beginner-handbook.md §5、docs/00-protocol-spec.md §5.1
//
//  约定：所有可再生的东西放 Library/Caches（系统可清理，语义正确），
//       用户数据与 bundle 放 Library/Application Support（会被 iCloud 备份，
//       所以 bundle 目录显式打上「不备份」标记）。
//

import Foundation
import CryptoKit

// MARK: - 沙箱路径

enum CatyPaths {

    private static let fm = FileManager.default

    static let stubSourceId = "dev-stub"

    /// Library/Application Support（默认不存在，必须 create: true）
    static func appSupport() throws -> URL {
        try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    /// Library/Caches（编译缓存等可再生数据）
    static func caches() throws -> URL {
        try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    /// Library/Logs
    static func ensureLogsDir() throws -> URL {
        let library = try fm.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try subdir(library, "Logs")
    }

    static func runtimeDir() throws -> URL {
        try subdir(try appSupport(), "runtime")
    }

    /// 一个源的全部落盘位置：sources/<id>/{data,bundles}
    static func sourceRoot(_ id: String) throws -> URL {
        try subdir(try appSupport(), "sources/\(safe(id))")
    }

    static func dataRoot(_ id: String) throws -> URL {
        try subdir(try sourceRoot(id), "data")
    }

    static func bundlesRoot(_ id: String) throws -> URL {
        try subdir(try sourceRoot(id), "bundles")
    }

    static func compileCacheDir() throws -> URL {
        try subdir(try caches(), "node-compile-cache")
    }

    /// 防目录穿越：只保留字母数字与 -_. ，其余替换成 _
    static func safe(_ id: String) -> String {
        String(id.map { character in
            character.isLetter || character.isNumber || "-_.".contains(character) ? character : "_"
        })
    }

    static func subdir(_ parent: URL, _ name: String) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 不让系统把它算进 iCloud 备份（bundle 是 6–9 MB 的可再生文件）
    static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }
}

// MARK: - 错误

enum RuntimeSetupError: LocalizedError {
    case missingResource(String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let name):
            return "App 资源里找不到 \(name)（检查它是否加进了 target 的 Copy Bundle Resources）"
        }
    }
}

// MARK: - 打桩源

struct StubBundle {
    let sourceId: String
    let indexFile: URL
    let configFile: URL
    let dataRoot: URL
}

// MARK: - 安装

enum BootstrapLoader {

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 把 App 内置的 bootstrap.js 落到沙箱（内容一致就不重写），返回沙箱路径。
    /// 为什么复制而不是直接用 App 包里的：App 包路径会随更新变化，
    /// 而 dataRoot 里的副本是稳定的；同时顺手做了完整性比对。
    @discardableResult
    static func installBootstrap() throws -> URL {
        guard let source = Bundle.main.url(forResource: "bootstrap", withExtension: "js") else {
            throw RuntimeSetupError.missingResource("bootstrap.js")
        }
        let data = try Data(contentsOf: source)
        let destination = try CatyPaths.runtimeDir().appendingPathComponent("bootstrap.js")

        if let existing = try? Data(contentsOf: destination),
           sha256Hex(existing) == sha256Hex(data) {
            CatyLog.shared.debug("runtime", "bootstrap.js 已是最新（sha256 \(sha256Hex(data).prefix(12))…）")
            return destination
        }

        try data.write(to: destination, options: .atomic)
        CatyLog.shared.info("runtime", "已安装 bootstrap.js（\(data.count)B）→ \(destination.path)")
        return destination
    }

    /// 把内置的打桩 bundle 放进它自己的数据目录：data/index.js + data/index.config.js
    /// （P2 只验证链路，不碰真源；P3 起换成真实下载的 bundle）
    static func installStubBundle() throws -> StubBundle {
        let id = CatyPaths.stubSourceId
        let dataRoot = try CatyPaths.dataRoot(id)
        CatyPaths.excludeFromBackup(try CatyPaths.sourceRoot(id))

        let indexFile = try copyResource(
            "stub-bundle.index", withExtension: "js",
            to: dataRoot.appendingPathComponent("index.js")
        )
        let configFile = try copyResource(
            "stub-bundle.index.config", withExtension: "js",
            to: dataRoot.appendingPathComponent("index.config.js")
        )
        CatyLog.shared.info("runtime", "打桩源已就位：\(dataRoot.path)")
        return StubBundle(sourceId: id, indexFile: indexFile, configFile: configFile, dataRoot: dataRoot)
    }

    @discardableResult
    private static func copyResource(_ name: String, withExtension ext: String, to destination: URL) throws -> URL {
        guard let source = Bundle.main.url(forResource: name, withExtension: ext) else {
            throw RuntimeSetupError.missingResource("\(name).\(ext)")
        }
        let data = try Data(contentsOf: source)
        if let existing = try? Data(contentsOf: destination), existing == data {
            return destination
        }
        try data.write(to: destination, options: .atomic)
        return destination
    }
}
