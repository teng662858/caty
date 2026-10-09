//
//  Theme.swift
//  设计 token（颜色 / 间距 / 圆角 / 字体），见 docs/02-ui-spec.md
//

import SwiftUI

enum Theme {

    // 主色：蓝紫（与设计稿一致）
    static let accent = Color(red: 0.36, green: 0.52, blue: 0.98)
    static let accentSoft = Color(red: 0.36, green: 0.52, blue: 0.98).opacity(0.18)

    static let cardRadius: CGFloat = 12
    static let posterRadius: CGFloat = 10
    static let chipRadius: CGFloat = 14

    static let padding: CGFloat = 14
    static let spacingS: CGFloat = 6
    static let spacingM: CGFloat = 10
    static let spacingL: CGFloat = 16

    /// 海报宽高比（2:3）
    static let posterAspect: CGFloat = 2.0 / 3.0

    static func posterColumns(_ count: Int) -> [GridItem] {
        let columns = max(2, min(5, count))
        return Array(repeating: GridItem(.flexible(), spacing: spacingM), count: columns)
    }
}

/// 统一的小胶囊标签（分类 / 线路 / 备注角标都用它）
struct ChipLabel: View {

    let text: String
    var selected = false
    var compact = false
    /// 首页用的"大一号"版式（用户反馈整体字号偏小）
    var large = false

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(selected ? Theme.accent.opacity(0.22) : Color.secondary.opacity(0.12))
            .foregroundStyle(selected ? Theme.accent : Color.primary)
            .clipShape(Capsule())
    }

    private var font: Font {
        if large { return compact ? .footnote : .subheadline }
        return compact ? .caption2 : .caption
    }

    private var horizontalPadding: CGFloat {
        if large { return 12 }
        return compact ? 8 : 12
    }

    private var verticalPadding: CGFloat {
        if large { return 7 }
        return compact ? 3 : 6
    }
}

/// 备注角标（海报右下角）
struct RemarksBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
