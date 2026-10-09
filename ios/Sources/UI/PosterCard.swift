//
//  PosterCard.swift
//  海报卡片与海报图（列表/网格共用）
//
//  图片走 URLCache（App 启动时配置成磁盘 500 MB / 内存 50 MB，见 CatyApp）。
//  源里的 vod_pic 常常是它自己的本地代理地址（/imageProxy?url=...），直接请求即可。
//

import SwiftUI

struct PosterImage: View {

    let urlString: String?
    /// 没有封面时显示的文字（用片名的前几个字当"文字封面"）
    var fallbackText: String?

    var body: some View {
        // 固定 2:3 的盒子：不管图片自身多大，格子永远一样大 → 网格整齐
        Rectangle()
            .fill(Color.secondary.opacity(0.12))
            .aspectRatio(Theme.posterAspect, contentMode: .fit)
            .overlay {
                // 用自己写的加载器（带 Referer/UA + 内存缓存），AsyncImage 在图床防盗链面前会白图
                RemoteImage(urlString: urlString, fallbackText: fallbackText)
            }
            .clipped()
    }
}

/// 网格里的海报卡片
struct PosterCard: View {

    let item: VodItem
    var showRemarks = true
    /// 片名字号（首页要"大一号"，其它格子保持原样）
    var titleFont: Font = .caption

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                PosterImage(urlString: item.pic, fallbackText: item.name)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.posterRadius))

                if showRemarks, let remarks = item.remarks, !remarks.isEmpty {
                    RemarksBadge(text: remarks)
                        .padding(4)
                }
            }
            // reservesSpace：片名一行还是两行都占两行高度 → 每格高度一致
            Text(item.name)
                .font(titleFont)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 横向列表里的行（列表模式用，比海报省空间）
struct VodRow: View {

    let item: VodItem
    var subtitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.spacingM) {
            PosterImage(urlString: item.pic, fallbackText: item.name)
                .frame(width: 54, height: 81)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.body).lineLimit(2)
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(Theme.accent)
                }
                if let remarks = item.remarks {
                    Text(remarks).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if let typeName = item.typeName {
                    Text(typeName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
