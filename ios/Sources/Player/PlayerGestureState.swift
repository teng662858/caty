//
//  PlayerGestureState.swift
//  播放手势（P6）：亮度 / 音量 / 快进 / 长按倍速 —— 小窗和全屏共用一套
//
//  规则（和主流播放器一致）：
//    左半边上下滑 = 亮度（系统亮度，UI 无公开的写入 API，只能改 UIScreen.brightness）
//    右半边上下滑 = 音量（iOS 没有公开的 setter，业界做法是拿 MPVolumeView 里那个 UISlider）
//    横向滑      = 快进/快退（每 6pt ≈ 1 秒）；小窗里"向下滑"仍然 = 关闭播放页
//    长按        = 临时 2 倍速
//  动作过程中画面中间显示 HUD，松手 0.8 秒后淡出。
//

import SwiftUI
import UIKit
import MediaPlayer
import AVKit

@MainActor
final class PlayerGestureState: ObservableObject {

    @Published var hud: GestureHUD?
    @Published var volume: Float = 0.5
    @Published var brightness: CGFloat = UIScreen.main.brightness

    private var volumeSlider: UISlider?
    private var hideTask: Task<Void, Never>?

    /// 拿到"设音量"用的隐藏滑块（MPVolumeView 里的那个）
    func prepare() {
        if volumeSlider == nil {
            let volumeView = MPVolumeView(frame: .zero)
            volumeView.showsRouteButton = false
            volumeSlider = volumeView.subviews.compactMap { $0 as? UISlider }.first
        }
        volume = volumeSlider?.value ?? AVAudioSession.sharedInstance().outputVolume
        brightness = UIScreen.main.brightness
    }

    /// 一个手势包办四种动作
    /// - onClose：小窗里"向下滑"时关闭播放页；全屏传 nil（全屏下滑不关）
    /// - dragOffset：小窗用它做"跟手位移"的动画；全屏不需要
    func dragGesture(controller: PlaybackController,
                     viewWidth: CGFloat,
                     onClose: (() -> Void)? = nil,
                     dragOffset: Binding<CGFloat>? = nil) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) > abs(dy) {
                    dragOffset?.wrappedValue = 0
                    let seconds = Double(dx) / 6.0
                    let total = controller.duration
                    let current = controller.position
                    let target = max(0, min(total > 0 ? total - 1 : current + seconds, current + seconds))
                    controller.seek(to: target)
                    hud = GestureHUD(kind: .seek, value: seconds,
                                     text: "\(seconds >= 0 ? "+" : "")\(Int(seconds)) 秒")
                    return
                }
                if let onClose, dy > 0, abs(dy) > abs(dx) * 1.2 {
                    dragOffset?.wrappedValue = dy        // 小窗：下滑关闭
                    hud = nil
                    _ = onClose
                    return
                }
                dragOffset?.wrappedValue = 0
                let delta = -Double(dy) / 260.0
                if value.startLocation.x < viewWidth / 2 {
                    brightness = min(1, max(0, brightness + CGFloat(delta)))
                    UIScreen.main.brightness = brightness
                    hud = GestureHUD(kind: .brightness, value: Double(brightness),
                                     text: "\(Int(brightness * 100))%")
                } else {
                    volume = min(1, max(0, volume + Float(delta)))
                    volumeSlider?.value = volume
                    hud = GestureHUD(kind: .volume, value: Double(volume),
                                     text: "\(Int(volume * 100))%")
                }
            }
            .onEnded { value in
                if let onClose, value.translation.height > 110 || value.predictedEndTranslation.height > 240 {
                    hud = nil
                    onClose()
                    return
                }
                if let dragOffset {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                        dragOffset.wrappedValue = 0
                    }
                }
                clearHUDSoon()
            }
    }

    /// 长按 2 倍速（按下显示 HUD，松开恢复）
    func pressingChanged(_ pressing: Bool, controller: PlaybackController, normalRate: Double) {
        if pressing {
            controller.setRate(2.0)
            hud = GestureHUD(kind: .rate, value: 2.0, text: "2 倍速播放中")
        } else {
            controller.setRate(normalRate)
            clearHUDSoon()
        }
    }

    func show(seconds: Double) {
        hud = GestureHUD(kind: .seek, value: seconds,
                         text: "\(seconds >= 0 ? "+" : "")\(Int(seconds)) 秒")
        clearHUDSoon()
    }

    func clearHUDSoon() {
        guard hud != nil else { return }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            hud = nil
        }
    }
}
