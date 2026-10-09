//
//  MPVVideoView.swift
//  把 libmpv 的 CAMetalLayer 挂到 SwiftUI 里（mpv 自己往这个图层画）
//
//  为什么要 UIView 子类：图层的 frame 必须跟着视图走。
//  注意：图层是**引擎持有**的，同一时刻只能挂在一个父图层上 ——
//  所以小窗切全屏时，后挂上去的那个视图会把它"搬"过去（CALayer 的行为），不需要我们手动搬。
//

import SwiftUI
import UIKit

final class MPVHostView: UIView {

    let surface: MPVVideoLayer

    init(surface: MPVVideoLayer) {
        self.surface = surface
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(surface)
        surface.frame = bounds
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.frame = bounds
        surface.drawableSize = CGSize(width: bounds.width * surface.contentsScale,
                                     height: bounds.height * surface.contentsScale)
        CATransaction.commit()
    }
}

struct MPVVideoView: UIViewRepresentable {

    let engine: MPVPlayerEngine

    func makeUIView(context: Context) -> MPVHostView {
        let view = MPVHostView(surface: engine.metalLayer)
        // 图层挂好之后再让 mpv 起来（mpv 初始化时会开始用这个图层）
        engine.prepare()
        return view
    }

    func updateUIView(_ uiView: MPVHostView, context: Context) {
        if uiView.surface !== engine.metalLayer {
            uiView.layer.addSublayer(engine.metalLayer)
        }
        uiView.setNeedsLayout()
    }
}
