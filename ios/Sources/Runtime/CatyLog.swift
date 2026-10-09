//
//  CatyLog.swift
//  统一日志：分级 / 环形缓冲 / 磁盘滚动 / 脱敏
//  规格来源：docs/05-data-model.md §5
//
//  设计要点：
//  - 线程安全（Node 的 stdout 采集、bridge、UI 都会并发写）
//  - 绝不写 stdout/stderr —— 因为启动 Node 前我们已把 fd 1/2 重定向到管道，
//    若日志再打 stdout 会被当成 Node 输出重新采集，形成回环。
//  - 脱敏在这里统一做：写进日志的 cookie/token/password 一律 <redacted len=n>
//

import Foundation

final class CatyLog {

    static let shared = CatyLog()

    enum Level: String, CaseIterable {
        case verbose, debug, info, warn, error

        var rank: Int {
            switch self {
            case .verbose: return 0
            case .debug: return 1
            case .info: return 2
            case .warn: return 3
            case .error: return 4
            }
        }
    }

    struct Line {
        let at: Date
        let level: Level
        let module: String
        let text: String

        var display: String {
            "[\(CatyLog.timeFormatter.string(from: at))][\(level.rawValue)][\(module)] \(text)"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - 配置

    /// 低于此级别的日志直接丢弃（默认 info 及以上，符合 docs/05 §5）
    var minLevel: Level = .info {
        didSet { }
    }

    private let ringCapacity = 2000
    private let fileMaxBytes = 2 * 1024 * 1024
    private let fileCount = 5

    // MARK: - 内部状态

    private let lock = NSLock()
    private var ring: [Line] = []
    private let ioQueue = DispatchQueue(label: "caty.log.io", qos: .utility)
    private var handle: FileHandle?
    private var bytesWritten = 0
    private var logDir: URL?

    private init() {
        logDir = try? CatyPaths.ensureLogsDir()
        openLogFile()
    }

    // MARK: - 写日志

    func verbose(_ module: String, _ text: String) { log(.verbose, module, text) }
    func debug(_ module: String, _ text: String) { log(.debug, module, text) }
    func info(_ module: String, _ text: String) { log(.info, module, text) }
    func warn(_ module: String, _ text: String) { log(.warn, module, text) }
    func error(_ module: String, _ text: String) { log(.error, module, text) }

    func log(_ level: Level, _ module: String, _ text: String) {
        guard level.rank >= minLevel.rank else { return }
        let safe = CatyLog.redact(text)
        let line = Line(at: Date(), level: level, module: module, text: safe)

        lock.lock()
        ring.append(line)
        if ring.count > ringCapacity { ring.removeFirst(ring.count - ringCapacity) }
        lock.unlock()

        let record = line.display + "\n"
        ioQueue.async { [weak self] in self?.appendToFile(record) }
    }

    // MARK: - 读取（界面 / 导出）

    func snapshot(last count: Int = 300) -> [Line] {
        lock.lock()
        defer { lock.unlock() }
        return Array(ring.suffix(count))
    }

    /// 导出为 .txt 全文（开头附环境头，见 docs/05 §5）
    func exportText(header: String) -> String {
        let body = snapshot(last: ringCapacity).map(\.display).joined(separator: "\n")
        return body.isEmpty ? header : header + "\n\n" + body
    }

    // MARK: - 磁盘滚动（5 个文件 × 2 MB）

    private func openLogFile() {
        guard let dir = logDir else { return }
        let url = dir.appendingPathComponent("caty.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        bytesWritten = size ?? 0
    }

    private func appendToFile(_ record: String) {
        guard let data = record.data(using: .utf8), let handle else { return }
        do {
            try handle.write(contentsOf: data)
            bytesWritten += data.count
        } catch {
            return
        }
        if bytesWritten > fileMaxBytes { rotate() }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        guard let dir = logDir else { return }
        let fm = FileManager.default
        for index in stride(from: fileCount - 1, through: 1, by: -1) {
            let source = dir.appendingPathComponent("caty.\(index).log")
            let target = dir.appendingPathComponent("caty.\(index + 1).log")
            try? fm.removeItem(at: target)
            try? fm.moveItem(at: source, to: target)
        }
        let current = dir.appendingPathComponent("caty.log")
        try? fm.removeItem(at: dir.appendingPathComponent("caty.1.log"))
        try? fm.moveItem(at: current, to: dir.appendingPathComponent("caty.1.log"))
        openLogFile()
    }

    // MARK: - 脱敏（硬要求，见 docs/05 §5）

    private static let userInfoRegex = try? NSRegularExpression(
        pattern: "(?i)\\b(https?://)([^/@\\s\"'<>]+)@",
        options: []
    )

    /// 匹配 `cookie`/`token`/`password` 等键值对，值替换为 <redacted len=n>
    private static let secretRegex = try? NSRegularExpression(
        pattern: "(?i)([\"']?(?:cookie|set-cookie|authorization|x-catvod-token|refresh_token|access_token|token|password|passwd|pwd|secret)[\"']?\\s*[:=]\\s*)([\"']?)([^\"'\\s,;&}\\]]+)",
        options: []
    )

    static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text

        if let regex = userInfoRegex {
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..<result.endIndex, in: result),
                withTemplate: "$1<user>:***@"
            )
        }

        if let regex = secretRegex {
            var replacements: [(Range<String.Index>, String)] = []
            regex.enumerateMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..<result.endIndex, in: result)
            ) { match, _, _ in
                guard let match, match.numberOfRanges >= 4,
                      let keyRange = Range(match.range(at: 1), in: result),
                      let quoteRange = Range(match.range(at: 2), in: result),
                      let valueRange = Range(match.range(at: 3), in: result)
                else { return }
                let prefix = String(result[keyRange]) + String(result[quoteRange])
                let replacement = prefix + "<redacted len=\(result[valueRange].count)>"
                replacements.append((keyRange.lowerBound..<valueRange.upperBound, replacement))
            }
            for (range, replacement) in replacements.reversed() {
                result.replaceSubrange(range, with: replacement)
            }
        }

        return result
    }
}
