import Foundation
import Network

/// 用于局域网内直接交换 SDP 的简单 TCP 信令服务
public class TCPSignalingService {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.foldersync.signaling", attributes: .concurrent)

    public var onReceiveSignal: ((SignalingMessage) -> Void)?

    public init() {}

    public func startServer() throws -> UInt16 {
        // 使用 TCP
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: 0)!)

        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(connection: connection)
        }

        let readyGroup = DispatchGroup()
        readyGroup.enter()

        var startError: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                readyGroup.leave()
            case .failed(let error):
                startError = error
                readyGroup.leave()
            default:
                break
            }
        }

        listener.start(queue: queue)
        self.listener = listener

        // Wait for ready state (timeout 5s)
        _ = readyGroup.wait(timeout: .now() + 5.0)

        if let error = startError {
            throw error
        }

        guard let port = listener.port?.rawValue else {
            throw NSError(
                domain: "TCPSignalingService", code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to bind port (state: \(listener.state))"
                ])
        }

        return port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    /// 发送信号给对方
    public func send(signal: SignalingMessage, to host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: .tcp)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                do {
                    let data = try JSONEncoder().encode(signal)
                    // 发送长度前缀 (4 bytes)
                    var lengthPrefix = UInt32(data.count).bigEndian
                    let prefixData = Data(bytes: &lengthPrefix, count: 4)

                    connection.send(
                        content: prefixData,
                        completion: .contentProcessed { error in
                            if error == nil {
                                connection.send(
                                    content: data,
                                    completion: .contentProcessed { _ in
                                        connection.cancel()  // 发完即断
                                    })
                            }
                        })
                } catch {
                    print("Signaling encode error: \(error)")
                    connection.cancel()
                }
            case .failed(_):
                connection.cancel()
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func receive(connection: NWConnection) {
        connection.start(queue: queue)
        // 读取长度
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) {
            [weak self] data, _, _, error in
            guard let data = data, data.count == 4 else {
                connection.cancel()
                return
            }
            let length = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            // 读取内容
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) {
                data, _, _, error in
                guard let data = data else {
                    connection.cancel()
                    return
                }

                if let signal = try? JSONDecoder().decode(SignalingMessage.self, from: data) {
                    self?.onReceiveSignal?(signal)
                }
                connection.cancel()
            }
        }
    }
}
