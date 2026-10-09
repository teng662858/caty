//
//  StateView.swift
//  五态组件：加载 / 空 / 错误 / 离线 / 骨架屏（docs/02-ui-spec.md 的五态矩阵）
//

import SwiftUI

struct StateView: View {

    enum Kind {
        case loading(String)
        case empty(String, hint: String?)
        case failure(String, hint: String?)
        case offline
    }

    let kind: Kind
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.spacingM) {
            icon
            Text(title).font(.headline).multilineTextAlignment(.center)
            if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let retry {
                Button("重试", action: retry)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.padding * 2)
    }

    @ViewBuilder
    private var icon: some View {
        switch kind {
        case .loading:
            ProgressView()
        case .empty:
            Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
        case .failure:
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
        case .offline:
            Image(systemName: "wifi.slash").font(.largeTitle).foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch kind {
        case .loading(let text): return text
        case .empty(let text, _): return text
        case .failure(let text, _): return text
        case .offline: return "已离线 · 显示缓存内容"
        }
    }

    private var hint: String? {
        switch kind {
        case .loading: return nil
        case .empty(_, let hint): return hint
        case .failure(_, let hint): return hint
        case .offline: return "网络恢复后会自动重试"
        }
    }
}

/// 海报墙骨架屏（加载时占位，避免白屏闪烁）
struct PosterSkeletonGrid: View {

    var columns: Int = 3
    var rows: Int = 3

    var body: some View {
        LazyVGrid(columns: Theme.posterColumns(columns), spacing: Theme.spacingM) {
            ForEach(0..<(max(1, columns) * max(1, rows)), id: \.self) { _ in
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: Theme.posterRadius)
                        .fill(Color.secondary.opacity(0.15))
                        .aspectRatio(Theme.posterAspect, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 10)
                }
            }
        }
        .padding(.horizontal, Theme.padding)
        .redacted(reason: .placeholder)
    }
}
