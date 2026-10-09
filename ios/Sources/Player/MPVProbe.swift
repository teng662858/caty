//
//  MPVProbe.swift
//  只是为了验证 MPVKit 预编译包能链接上（P6 第一步）
//
//  它不参与播放：App 启动时把 mpv 的客户端 API 版本打一条日志。
//  真正的播放器在 MPVPlayerEngine.swift。等那边稳定了，这个文件可以删。
//

import Foundation
import Libmpv

enum MPVProbe {

    /// mpv 客户端 API 版本（编译期头文件与运行期库一致才正常）
    static func logVersion() {
        let version = mpv_client_api_version()
        CatyLog.shared.info("player", "libmpv 已链接：client api version=\(version >> 16).\(version & 0xffff)")
    }
}
