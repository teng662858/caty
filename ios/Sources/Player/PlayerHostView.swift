//
//  PlayerHostView.swift
//  播放画面宿主（P6+）：AVPlayerLayer + 画中画
//
//  为什么不用 SwiftUI 的 VideoPlayer / AVPlayerViewController：
//   · 我们要自己的控制层，系统控件要全关掉
//   · **画中画**只有 AVPictureInPictureController(playerLayer:) 这条公开路子能"用代码启动"，
//     它需要我们自己的 AVPlayerLayer ✓（AVPlayerViewController 只能靠它自带的按钮）
//   · 画面比例（自适应 / 铺满）也就是 AVPlayerLayer 的 videoGravity 一行
//
//  mpv 内核不用这个：mpv 把画面渲染进 CAMetalLayer（MPVVideoView），画中画用不了。
//

import SwiftUI
import AVKit

/// 持有 AVPlayerLayer / PiP 控制器，让"画中画按钮"能触发它
final class PiPHandle: NSObject, ObservableObject {

    @Published private(set) var isActive = false
    @Published private(set) var isSupported = AVPictureInPictureController.isPictureInPictureSupported()

    fileprivate var pipController: AVPictureInPictureController?

    func start() {
        guard let pipController, !pipController.isPictureInPictureActive else { return }
        pipController.startPictureInPicture()
    }

    func stop() {
        guard let pipController, pipController.isPictureInPictureActive else { return }
        pipController.stopPictureInPicture()
    }

    fileprivate func update(active: Bool) {
        if isActive != active { isActive = active }
    }
}

/// 画面比例选项（控制层"比例"按钮循环用）
enum PlayerAspectMode: String, CaseIterable {
    case fit, fill, ratio16x9, ratio4x3

    var label: String {
        switch self {
        case .fit: return "自适应"
        case .fill: return "铺满"
        case .ratio16x9: return "16:9"
        case .ratio4x3: return "4:3"
        }
    }

    var next: PlayerAspectMode {
        let all = PlayerAspectMode.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    /// 固定比例（nil = 用视频自己的比例）
    var fixedAspect: Double? {
        switch self {
        case .fit, .fill: return nil
        case .ratio16x9: return 16.0 / 9.0
        case .ratio4x3: return 4.0 / 3.0
        }
    }

    var fills: Bool { self == .fill }
}

/// AVPlayerLayer 宿主
final class PlayerLayerView: UIView {

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }
}

struct PlayerHostView: UIViewRepresentable {

    let player: AVPlayer
    let fill: Bool
    let pip: PiPHandle

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView(frame: .zero)
        view.playerLayer.player = player
        attachPiP(for: view)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if view.playerLayer.videoGravity != gravity {
            view.playerLayer.videoGravity = gravity
        }
        attachPiP(for: view)
    }

    private func attachPiP(for view: PlayerLayerView) {
        guard pip.isSupported else { return }
        if pip.pipController == nil {
            let controller = AVPictureInPictureController(playerLayer: view.playerLayer)
            controller?.delegate = PiPDelegate.shared
            pip.pipController = controller
            PiPDelegate.shared.handle = pip
        }
    }
}

/// PiP 状态回调（画中画开始/结束 → 更新按钮状态）
final class PiPDelegate: NSObject, AVPictureInPictureControllerDelegate {

    static let shared = PiPDelegate()
    weak var handle: PiPHandle?

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        DispatchQueue.main.async { self.handle?.update(active: true) }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        DispatchQueue.main.async { self.handle?.update(active: false) }
    }
}
