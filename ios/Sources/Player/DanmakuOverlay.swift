//
//  DanmakuOverlay.swift
//  弹幕渲染层（Canvas 画，不用一条一个 View）
//
//  为什么不用 SwiftUI 视图：一集弹幕动辄几万条，做成 View 会直接卡死。
//
//  2026-10-11 性能重做（用户反馈"弹幕很卡"）—— 每帧的开销必须和弹幕总条数无关：
//   · 一帧只处理"屏幕上还看得见的那几十条"：弹幕按时间升序，用**二分查找**定位窗口。
//     旧写法每帧都对整集 `comments.filter` 全表扫一遍（几万条 × 15 帧/秒）。
//   · 文本宽度缓存搬进带锁的类：不再写 SwiftUI 状态。
//     旧写法在 Canvas 绘制过程中异步回写 @State，每帧都能触发一次"失效 → 重绘"，
//     实测会退化成刷屏式重绘；缓存撑到 4000 条还会整表清空，然后又从头测一遍。
//   · 加轨道避让：同一轨道上一条的尾巴没完全进屏幕就不许再放，放不下就丢掉这一条；
//     一帧最多画 140 条 → 弹幕再密也不会叠着一堆画。
//   · 位置换算：弹幕按"出现时间"排队，出现后从右往左匀速滑过（默认 8 秒走完一屏）。
//     播放位置由调用方用"采样位置 + 过去的时间"外推，快进/倍速下也能跟上。
//

import SwiftUI
import UIKit

/// 弹幕文本宽度缓存（跨帧、跨视图共用；绘制时只读，不碰 SwiftUI 状态）
final class DanmakuMetrics {

    static let shared = DanmakuMetrics()

    private var cache: [String: CGFloat] = [:]
    private let lock = NSLock()
    private let limit = 8000

    private init() {}

    func width(_ text: String, fontSize: CGFloat) -> CGFloat {
        let key = String(Int(fontSize)) + "|" + text

        lock.lock()
        let hit = cache[key]
        lock.unlock()
        if let hit { return hit }

        let font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
        let measured = (text as NSString).size(withAttributes: [.font: font]).width + 12

        lock.lock()
        if cache.count >= limit { cache.removeAll() }
        cache[key] = measured
        lock.unlock()
        return measured
    }
}

struct DanmakuOverlay: View {

    let comments: [DanmakuComment]
    /// 播放进度提供者（外推用）
    let position: () -> Double
    let isPlaying: () -> Bool
    /// 用户在「设置 → 弹幕」里的选择
    var fontSize: CGFloat = 17
    var opacity: Double = 1.0
    var laneSpacing: CGFloat = 1.6
    var showTop = true
    var showBottom = true
    var blockWords: [String] = []

    /// 一条弹幕从右边滑到左边用多久
    private let travel: Double = 8
    /// 一帧最多画多少条（先到先得）
    private let frameBudget = 140
    /// 顶部/底部固定弹幕各显示几秒
    private let fixedSeconds: Double = 4
    /// 顶/底固定弹幕各给几行
    private let fixedSlots = 4

    private var laneHeight: CGFloat { max(14, fontSize * laneSpacing) }

    var body: some View {
        // 暂停时把时间线停掉：弹幕本来就不会动，别再每帧重画（省 CPU/电，也是"卡"的一个来源）
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isPlaying())) { _ in
            Canvas { context, size in
                guard !comments.isEmpty else { return }
                let now = position()
                guard now.isFinite else { return }
                context.opacity = opacity
                for sprite in sprites(now: now, size: size) {
                    context.draw(textView(for: sprite),
                                 at: CGPoint(x: sprite.x, y: sprite.y),
                                 anchor: .center)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - 这一帧要画的东西（纯计算，不碰状态）

    private struct Sprite {
        let text: String
        let color: UInt32
        let x: CGFloat
        let y: CGFloat
    }

    private func sprites(now: Double, size: CGSize) -> [Sprite] {
        let laneCount = max(1, Int(size.height / laneHeight))
        // 每条轨道"可以再放一条"的时刻（上一条的尾巴完全进屏幕之后）
        var free = [Double](repeating: -.greatestFiniteMagnitude, count: laneCount)
        // 顶/底固定弹幕的行占用
        var topFree = [Double](repeating: -.greatestFiniteMagnitude, count: fixedSlots)
        var bottomFree = [Double](repeating: -.greatestFiniteMagnitude, count: fixedSlots)
        var result: [Sprite] = []
        result.reserveCapacity(64)

        // 窗口起点比"屏幕上还能看见的"再往前一点：轨道分配只跟这个窗口有关，
        // 每帧重算同一个窗口 → 同一条弹幕不会在两帧之间换轨道（不会抖）。
        var index = lowerBound(now - travel - 2)
        while index < comments.count, result.count < frameBudget {
            let comment = comments[index]
            index += 1
            if comment.time > now + 1.5 { break }
            if isBlocked(comment.text) { continue }

            if comment.mode == 4 || comment.mode == 5 {
                let top = comment.mode == 5
                if top, !showTop { continue }
                if !top, !showBottom { continue }
                let slot: Int
                if top {
                    slot = reserve(&topFree, at: comment.time,
                                   until: comment.time + fixedSeconds, limit: fixedSlots)
                } else {
                    slot = reserve(&bottomFree, at: comment.time,
                                   until: comment.time + fixedSeconds, limit: fixedSlots)
                }
                guard slot >= 0 else { continue }
                if comment.time > now || now - comment.time > fixedSeconds { continue }
                let offset = laneHeight * (CGFloat(slot) + 0.8)
                result.append(Sprite(text: comment.text,
                                     color: comment.color,
                                     x: size.width / 2,
                                     y: top ? offset : size.height - offset))
                continue
            }

            // 滚动弹幕
            let width = DanmakuMetrics.shared.width(comment.text, fontSize: fontSize)
            let lane = reserveLane(&free, at: comment.time, laneCount: laneCount)
            guard lane >= 0 else { continue }
            // 尾巴进屏幕所需的时间（这条轨道下一次能用的时刻）
            free[lane] = comment.time + travel * width / (max(1, size.width) + width)
            if comment.time > now || now - comment.time > travel { continue }
            let progress = (now - comment.time) / travel
            let x = size.width - CGFloat(progress) * (size.width + width) + width / 2
            result.append(Sprite(text: comment.text,
                                 color: comment.color,
                                 x: x,
                                 y: laneHeight * (CGFloat(lane) + 0.5) + 4))
        }
        return result
    }

    /// 占一行（顶/底固定弹幕用）；行满返回 -1
    private func reserve(_ rows: inout [Double], at time: Double, until: Double, limit: Int) -> Int {
        var chosen = -1
        var chosenFree = Double.greatestFiniteMagnitude
        for row in 0..<limit where rows[row] <= time && rows[row] < chosenFree {
            chosen = row
            chosenFree = rows[row]
        }
        if chosen >= 0 { rows[chosen] = until }
        return chosen
    }

    /// 占一条轨道（滚动弹幕用，挑最早空出来的那条）；满了返回 -1（这一条就不画了）
    private func reserveLane(_ lanes: inout [Double], at time: Double, laneCount: Int) -> Int {
        var chosen = -1
        var chosenFree = Double.greatestFiniteMagnitude
        for lane in 0..<laneCount where lanes[lane] <= time && lanes[lane] < chosenFree {
            chosen = lane
            chosenFree = lanes[lane]
        }
        return chosen
    }

    private func textView(for sprite: Sprite) -> Text {
        Text(sprite.text)
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(colorOf(sprite.color))
    }

    // MARK: - 小工具

    /// 二分：第一条 `time >= target` 的弹幕的下标（弹幕按时间升序，见 DanmakuStore）
    private func lowerBound(_ target: Double) -> Int {
        var low = 0
        var high = comments.count
        while low < high {
            let mid = (low + high) / 2
            if comments[mid].time < target { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// 屏蔽词（设置里能加，逗号分隔）
    private func isBlocked(_ text: String) -> Bool {
        guard !blockWords.isEmpty else { return false }
        for word in blockWords where !word.isEmpty && text.contains(word) { return true }
        return false
    }

    private func colorOf(_ value: UInt32) -> Color {
        // 0xRRGGBB；全黑/全白的都用白字更清楚
        if value == 0 || value == 0xFFFFFF {
            return .white
        }
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        return Color(red: red, green: green, blue: blue)
    }
}
