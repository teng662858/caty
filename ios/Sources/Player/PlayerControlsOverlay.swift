//
//  PlayerControlsOverlay.swift
//  播放控制层（P6+）—— 整合同类 App 的版式：
//
//    顶部：返回/关闭 · 剧名·集·线路 · 一排图标（弹幕 / 截图 / 画中画 / 比例 / 旋转 / 锁）
//    中间：±10 秒 · 大播放键
//    底部：信息行（分辨率·速度）· 进度条（时间 / 剩余）· 上一集/播放/下一集 · 胶囊（片头 / 弹幕 / 选集 / 倍速 / 比例）
//    锁定：锁上后只剩解锁键，其余控制和手势全失效（防误触）
//
//  ⚠️ 结构上刻意"少参数、小块"：
//  把十几个参数直接摊成一个 View 的成员，swift-frontend 崩过一次（CI 定位到的），
//  所以这里用 state + actions 两个结构体承载，每个区域是独立的 @ViewBuilder 小函数。
//

import SwiftUI
import UIKit

/// 弹一个系统的"选集"菜单（小窗和全屏共用；菜单挂在最上层控制器上）
func presentEpisodePicker(_ episodes: [Episode], currentIndex: Int, onSelect: @escaping (Int) -> Void) {
    guard !episodes.isEmpty else { return }
    let sheet = UIAlertController(title: "选集", message: nil, preferredStyle: .actionSheet)
    for (i, episode) in episodes.enumerated() {
        let title = i == currentIndex ? "✓ " + episode.name : episode.name
        sheet.addAction(UIAlertAction(title: title, style: .default) { _ in onSelect(i) })
    }
    sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
    if let popover = sheet.popoverPresentationController {
        popover.sourceView = UIApplication.shared.windows.first
    }
    UIApplication.shared.catyTopViewController()?.present(sheet, animated: true)
}

/// 控制层要显示的状态
struct PlayerChromeState {
    var isFullscreen = false
    /// 小窗模式：竖屏播放页里画面只有两三百点高，按钮要小一号、少一排（返回/旋转之类的交给页面本身）
    var compact = false
    var title = ""
    var subtitle = ""
    var position: Double = 0
    var duration: Double = 0
    var isLive = false
    var isPlaying = false
    var rate: Double = 1.0
    var danmakuEnabled = false
    var danmakuCount = 0
    var infoLine = ""
    var aspectLabel = "自适应"
    var introSeconds = 0
    var locked = false
}

/// 控制层的动作
struct PlayerChromeActions {
    var close: () -> Void = {}
    var togglePlay: () -> Void = {}
    var seek: (Double) -> Void = { _ in }
    var seekBy: (Double) -> Void = { _ in }
    var previousEpisode: () -> Void = {}
    var nextEpisode: () -> Void = {}
    var setRate: (Double) -> Void = { _ in }
    var toggleDanmaku: () -> Void = {}
    var selectEpisode: () -> Void = {}
    var toggleFullscreen: () -> Void = {}
    var rotate: () -> Void = {}
    var cycleAspect: () -> Void = {}
    var pictureInPicture: () -> Void = {}
    var screenshot: () -> Void = {}
    var skipIntro: () -> Void = {}
    var setLocked: (Bool) -> Void = { _ in }
}

struct PlayerControlsOverlay: View {

    let state: PlayerChromeState
    let actions: PlayerChromeActions

    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        ZStack {
            if state.locked {
                lockOnlyView
            } else {
                controlsView
            }
        }
    }

    // MARK: - 控制层

    private var controlsView: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            centerBar
            Spacer(minLength: 0)
            bottomBar
        }
        .padding(.horizontal, state.compact ? 10 : Theme.padding)
        .padding(.vertical, state.compact ? 6 : 10)
    }

    @ViewBuilder
    private var topBar: some View {
        if state.compact {
            compactTopBar
        } else {
            fullTopBar
        }
    }

    /// 小窗：返回 + 剧名（一行）+ 弹幕 / 比例 / 锁
    /// （截图、画中画放在画面下方的信息区，那里有地方放大一点的按钮）
    private var compactTopBar: some View {
        HStack(spacing: 4) {
            iconButton(icon: "chevron.down", size: 32) { actions.close() }
            titleBlock
            Spacer(minLength: 4)
            iconButton(icon: "text.bubble", active: state.danmakuEnabled, size: 32) { actions.toggleDanmaku() }
            iconButton(icon: "arrow.up.left.and.arrow.down.right", size: 32) { actions.toggleFullscreen() }
            iconButton(icon: "aspectratio", size: 32) { actions.cycleAspect() }
            iconButton(icon: "lock.open", size: 32) { actions.setLocked(true) }
        }
    }

    /// 全屏：返回 + 剧名 + 一整排图标（多了"旋转"和"进/退全屏"）
    private var fullTopBar: some View {
        HStack(spacing: 8) {
            iconButton(icon: state.isFullscreen ? "chevron.down" : "chevron.backward") { actions.close() }
            titleBlock
            Spacer(minLength: 0)
            iconButton(icon: "text.bubble", active: state.danmakuEnabled) { actions.toggleDanmaku() }
            iconButton(icon: "camera") { actions.screenshot() }
            iconButton(icon: "pip.enter") { actions.pictureInPicture() }
            iconButton(icon: "aspectratio") { actions.cycleAspect() }
            iconButton(icon: "rotate.right") { actions.rotate() }
            iconButton(icon: "lock.open") { actions.setLocked(true) }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(state.title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)
            if !state.subtitle.isEmpty {
                Text(state.subtitle)
                    .font(.caption2)
                    .opacity(0.8)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
    }

    private var centerBar: some View {
        HStack {
            centerButton(icon: "gobackward.10") { actions.seekBy(-10) }
            Spacer(minLength: 20)
            centerButton(icon: state.isPlaying ? "pause.fill" : "play.fill") { actions.togglePlay() }
            Spacer(minLength: 20)
            centerButton(icon: "goforward.10") { actions.seekBy(10) }
        }
        .padding(.horizontal, state.compact ? 20 : 30)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if !state.infoLine.isEmpty {
                Text(state.infoLine)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            progressRow
            actionRow
        }
    }

    @ViewBuilder
    private var progressRow: some View {
        if state.isLive {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("直播中").font(.caption).foregroundStyle(.white)
                Spacer()
            }
        } else {
            durationRow
        }
    }

    private var durationRow: some View {
        VStack(spacing: 2) {
            Slider(value: bindingForScrub, in: 0...max(1, state.duration)) { editing in
                if !editing {
                    scrubbing = false
                    actions.seek(scrubValue)
                }
            }
            .tint(.white)
            HStack {
                Text(PlayerControlsOverlay.timeText(state.position))
                    .font(.caption2)
                    .foregroundStyle(.white)
                Spacer()
                Text("-" + PlayerControlsOverlay.timeText(max(0, state.duration - state.position)))
                    .font(.caption2)
                    .foregroundStyle(.white)
            }
        }
    }

    private var bindingForScrub: Binding<Double> {
        Binding(get: {
            scrubbing ? scrubValue : state.position
        }, set: { newValue in
            scrubbing = true
            scrubValue = newValue
        })
    }

    private var actionRow: some View {
        HStack(spacing: state.compact ? 8 : 10) {
            // 小窗中间已经有大播放键和 ±10 了，这里只留"上一集/下一集"
            if state.compact {
                iconButton(icon: "backward.end.fill", size: 30) { actions.previousEpisode() }
                iconButton(icon: "forward.end.fill", size: 30) { actions.nextEpisode() }
            } else {
                iconButton(icon: "backward.end.fill") { actions.previousEpisode() }
                iconButton(icon: state.isPlaying ? "pause.fill" : "play.fill") { actions.togglePlay() }
                iconButton(icon: "forward.end.fill") { actions.nextEpisode() }
            }

            Spacer(minLength: 4)

            pillRow
        }
    }

    @ViewBuilder
    private var pillRow: some View {
        if state.introSeconds > 0 {
            pillButton(title: "片头\(state.introSeconds)s", active: false) { actions.skipIntro() }
        }
        // 小窗顶栏已经有"弹幕"和"比例"两个图标了，这里不重复放（一行塞不下那么多胶囊）
        if !state.compact {
            pillButton(title: state.danmakuEnabled ? "弹幕开" : "弹幕", active: state.danmakuEnabled) {
                actions.toggleDanmaku()
            }
        }
        pillButton(title: "选集", active: false) { actions.selectEpisode() }
        pillButton(title: rateLabel, active: state.rate != 1.0) { actions.setRate(nextRate) }
        if !state.compact {
            pillButton(title: state.aspectLabel, active: false) { actions.cycleAspect() }
        }
    }

    private var lockOnlyView: some View {
        VStack {
            Spacer()
            HStack {
                Button {
                    actions.setLocked(false)
                } label: {
                    Image(systemName: "lock.fill")
                        .font(.title3)
                        .padding(12)
                        .background(.black.opacity(0.45), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    // MARK: - 小零件与工具

    private func iconButton(icon: String, active: Bool = false, size: CGFloat = 34,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: max(11, size * 0.42)))
                .frame(width: size, height: size)
                .background(active ? Theme.accent : Color.black.opacity(0.35), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func centerButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 54, height: 54)
                .background(.black.opacity(0.32), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func pillButton(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, state.compact ? 9 : 12)
                .padding(.vertical, state.compact ? 6 : 7)
                .background(active ? Theme.accent : Color.black.opacity(0.35), in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var rateLabel: String {
        state.rate == 1.0 ? "倍速" : String(format: "%gx", state.rate)
    }

    private var nextRate: Double {
        let all: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]
        let index = all.firstIndex(of: state.rate) ?? 2
        return all[(index + 1) % all.count]
    }

    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
