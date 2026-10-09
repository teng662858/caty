//
//  BridgeServer.swift
//  /msg 桥 + 自检端点（宿主侧，等价 FongMi 的 NodeService 桥）
//
//  规格来源：docs/00-protocol-spec.md §2.3
//    POST /msg     收 bundle 的 serverStarted / nodeError，必须带 X-CatVod-Token
//    GET  /health  宿主自检 JSON（App 内部用，验证「Swift → 回环 HTTP」这条路）
//
//  安全：只绑定 127.0.0.1（requiredLocalEndpoint 强制回环），端口由系统随机分配，
//        token 每次启动重新生成 —— 其它 App 无法从局域网打进来。
//        回环地址在 iOS 上不需要「本地网络」权限。
//

import Foundation
import Network

struct BridgeRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var pathOnly: String {
        String(path.split(separator: "?", maxSplits: 1).first ?? "")
    }
}

final class BridgeServer {

    struct Message {
        let action: String
        let opt: [String: Any]
    }

    /// 32 位 hex，每次启动重新生成
    let token: String

    /// 收到 bundle 的回报（在 main 队列回调）
    var onMessage: ((Message) -> Void)?

    /// /health 的响应体（必须线程安全，见 NodeRuntime.healthBox）
    var healthProvider: (() -> [String: Any])?

    private let queue = DispatchQueue(label: "caty.bridge")
    private var listener: NWListener?
    private var startCompletion: ((Result<UInt16, Error>) -> Void)?

    private(set) var port: UInt16 = 0

    init(token: String) {
        self.token = token
    }

    // MARK: - 生命周期

    func start(completion: @escaping (Result<UInt16, Error>) -> Void) {
        startCompletion = completion
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // 强制只监听回环 + 系统分配端口（port .any）
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let assigned = listener.port?.rawValue ?? 0
                    self.port = assigned
                    self.finishStart(.success(assigned))
                case .failed(let error):
                    self.finishStart(.failure(error))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            finishStart(.failure(error))
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
        }
    }

    private func finishStart(_ result: Result<UInt16, Error>) {
        guard let completion = startCompletion else { return }
        startCompletion = nil
        DispatchQueue.main.async { completion(result) }
    }

    // MARK: - 连接处理

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        BridgeConnection(connection: connection, server: self).receive()
    }

    fileprivate func handle(_ request: BridgeRequest, respond: @escaping (Int, Data) -> Void) {
        if request.method == "POST" && request.pathOnly == "/msg" {
            guard request.headers["x-catvod-token"] == token else {
                CatyLog.shared.warn("bridge", "拒绝一个 token 不匹配的 /msg 请求")
                respond(403, Data(#"{"error":"forbidden"}"#.utf8))
                return
            }
            var action = ""
            var opt: [String: Any] = [:]
            if let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] {
                action = object["action"] as? String ?? ""
                opt = object["opt"] as? [String: Any] ?? [:]
            }
            respond(200, Data("{}".utf8))
            if !action.isEmpty {
                let message = Message(action: action, opt: opt)
                DispatchQueue.main.async { [weak self] in self?.onMessage?(message) }
            } else {
                CatyLog.shared.warn("bridge", "收到无法解析的 /msg 请求（body \(request.body.count)B）")
            }
            return
        }

        if request.method == "GET" && request.pathOnly == "/health" {
            let payload = healthProvider?() ?? ["ok": true]
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
                ?? Data(#"{"ok":true}"#.utf8)
            respond(200, data)
            return
        }

        respond(404, Data(#"{"error":"not_found"}"#.utf8))
    }

    fileprivate func encodeResponse(status: Int, body: Data) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 500: reason = "Internal Server Error"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}

// MARK: - 单条连接（极简 HTTP/1.1：够 /msg 与 /health 用）

private final class BridgeConnection {

    private let connection: NWConnection
    private weak var server: BridgeServer?
    private var buffer = Data()

    private let maxBodyBytes = 1 << 20   // 1 MB，超出即断开

    init(connection: NWConnection, server: BridgeServer) {
        self.connection = connection
        self.server = server
    }

    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                CatyLog.shared.debug("bridge", "连接读取结束：\(error.localizedDescription)")
                self.close()
                return
            }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if let request = self.parseIfComplete() {
                    self.dispatch(request)
                    return
                }
            }
            if isComplete {
                self.close()
                return
            }
            self.receive()
        }
    }

    /// 解析完整请求；不完整返回 nil 继续收
    private func parseIfComplete() -> BridgeRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 64 * 1024 { close() }
            return nil
        }
        let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            close()
            return nil
        }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            close()
            return nil
        }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else {
            close()
            return nil
        }
        let method = String(requestLine[0]).uppercased()
        let path = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength <= maxBodyBytes else {
            close()
            return nil
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.count >= bodyStart + contentLength else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        return BridgeRequest(method: method, path: path, headers: headers, body: body)
    }

    private func dispatch(_ request: BridgeRequest) {
        guard let server else {
            close()
            return
        }
        server.handle(request) { [weak self] status, body in
            self?.respond(status: status, body: body)
        }
    }

    private func respond(status: Int, body: Data) {
        guard let server else {
            close()
            return
        }
        let payload = server.encodeResponse(status: status, body: body)
        connection.send(content: payload, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private func close() {
        connection.cancel()
    }
}
