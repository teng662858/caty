//
//  DanmakuOverlay.swift
//  弹幕渲染层（Canvas 画，不用一条一个 View）
//
//  为什么不用 SwiftUI 视图：一集弹幕动辄几万条，做成 View 会直接卡死；
//  Canvas 每帧只画"当前可见的几十条"，开销可控。
//
//  位置换算：弹幕按"出现时间"排队，出现后从右往左匀速滑过（默认 8 秒走完一个屏幕宽）。
//  播放位置用 controller.position + 这之后过去的时间**外推**，这样快进/倍速下也能跟上。
//

import SwiftUI

struct DanmakuOverlay: View {

    let comments: [DanmakuComment]
    /// 播放进度提供者（外推用）
    let position: () -> Double
    let isPlaying: () -> Bool
    var fontSize: CGFloat = 15

    /// 每条弹幕的文本宽度（按需测量并缓存 —— 每帧都测会卡）
    @State private var widths: [String: CGFloat] = [:]

    private let duration: Double = 8          // 一条弹幕滑过屏幕用多久
    private let laneHeight: CGFloat = 22
    private let speedRate: Double = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
            Canvas { context, size in
                guard !comments.isEmpty else { return }
                let now = position()
                let laneCount = max(1, Int(size.height / laneHeight))
                for comment in activeComments(around: now, width: size.width, now: timeline.date) {
                    let width = widthOf(comment.text)
                    let elapsed = now - comment.time
                    let progress = min(1.0, max(0, elapsed / duration))
                    let x = size.width - CGFloat(progress) * (size.width + width) + width / 2
                    let lane = laneFor(comment, laneCount: laneCount)
                    let y = laneHeight * (CGFloat(lane) + 0.5) + 4
                    var text = Text(comment.text)
                        .font(.system(size: fontSize, weight: .medium))
                    context.draw(text.foregroundStyle(colorOf(comment.color)), at: CGPoint(x: x, y: y), anchor: .center)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// 只挑"当前这段窗口里应该出现"的弹幕（给 Canvas 少画点）
    private func activeComments(around now: Double, width: CGFloat, now date: Date) -> [DanmakuComment] {
        let lower = now - duration - 0.5
        let upper = now + 1.5
        return comments.filter { $0.time >= lower && $0.time <= upper && $0.mode != 4 && $0.mode != 5 }
    }

    /// 轨道分配：用 id 取模，简单稳定（避免同一条弹幕在两帧之间跳轨道）
    private func laneFor(_ comment: DanmakuComment, laneCount: Int) -> Int {
        abs(comment.id &* 2654435761) % laneCount
    }

    private func widthOf(_ text: String) -> CGFloat {
        if let hit = widths[text] { return hit }
        let measured = (text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: fontSize, weight: .medium)]).width + 12
        DispatchQueue.main.async { widths[text] = measured }
        // 缓存别无限涨（一集几万条文本可能都不一样）
        if widths.count > 4000 { widths.removeAll() }
        return measured
    }

    private func colorOf(_ value: UInt32) -> Color {
        // 0xRRGGBB；全黑/全白的都用白字 + 阴影更清楚
        if value == 0 || value == 0xFFFFFF {
            return .white
        }
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        return Color(red: red, green: green, blue: blue)
    }
}
