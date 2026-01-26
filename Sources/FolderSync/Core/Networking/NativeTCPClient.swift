import Foundation
import Network

/// 原生 TCP 客户端 - 用于与对等点通信
public class NativeTCPClient: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.foldersync.nativetcp.client", attributes: .concurrent)

    // 连接去重：跟踪正在进行的连接，避免对同一地址重复连接（使用 actor 以兼容异步上下文）
    private actor ConnectionStore {
        private var activeConnections: [String: Task<Data, Error>] = [:]
        func task(for address: String) -> Task<Data, Error>? { activeConnections[address] }
        func set(_ task: Task<Data, Error>, for address: String) {
            activeConnections[address] = task
        }
        func remove(address: String) { activeConnections.removeValue(forKey: address) }
    }

    private let connectionStore = ConnectionStore()

    public init() {}

    /// 发送请求到对等点
    /// - Parameters:
    ///   - message: 同步请求消息
    ///   - address: 对等点地址（格式：ip:port）
    ///   - timeout: 超时时间（秒）
    ///   - useTLS: 是否使用 TLS 加密（默认 false）
    /// - Returns: 响应数据
    public func sendRequest(
        _ message: SyncRequest, to address: String, timeout: TimeInterval = 30.0,
        useTLS: Bool = false
    ) async throws -> Data {
        // 检查是否已有相同地址的连接正在进行
        if let existingTask = await connectionStore.task(for: address) {
            // 等待现有连接完成
            return try await existingTask.value
        }

        // 解析地址
        let components = address.split(separator: ":")
        guard components.count == 2 else {
            throw NSError(
                domain: "NativeTCPClient", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无效的地址格式: \(address) (期望格式: IP:Port)"])
        }

        let host = String(components[0]).removingPercentEncoding ?? String(components[0])
        let portString = String(components[1]).removingPercentEncoding ?? String(components[1])

        guard let port = UInt16(portString), port > 0, port <= 65535 else {
            throw NSError(
                domain: "NativeTCPClient", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无效的端口: \(portString) (地址: \(address))"])
        }

        // 编码请求
        let requestData = try JSONEncoder().encode(message)

        // 创建连接任务
        let connectionTask = Task<Data, Error> {
            do {
                let data = try await performConnection(
                    host: host, port: port, address: address, requestData: requestData,
                    timeout: timeout, useTLS: useTLS)
                await connectionStore.remove(address: address)
                return data
            } catch {
                await connectionStore.remove(address: address)
                throw error
            }
        }

        // 记录活动连接
        await connectionStore.set(connectionTask, for: address)

        return try await connectionTask.value
    }

    private func performConnection(
        host: String, port: UInt16, address: String, requestData: Data, timeout: TimeInterval,
        useTLS: Bool
    ) async throws -> Data {

        // 创建连接
        let hostEndpoint = NWEndpoint.Host(host)
        let portEndpoint = NWEndpoint.Port(rawValue: port)!
        let endpoint = NWEndpoint.hostPort(host: hostEndpoint, port: portEndpoint)

        let parameters: NWParameters
        if useTLS {
            // 使用 TLS 加密
            parameters = NWParameters(tls: NWProtocolTLS.Options())
            parameters.allowLocalEndpointReuse = true
        } else {
            // 使用普通 TCP
            parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
        }
        // 不限制接口类型，允许使用任何可用网络
        let connection = NWConnection(to: endpoint, using: parameters)

        return try await withCheckedThrowingContinuation { continuation in
            let hasCompletedLock = NSLock()
            var hasCompleted = false

            func checkAndResume(_ action: () -> Void) -> Bool {
                hasCompletedLock.lock()
                defer { hasCompletedLock.unlock() }
                if !hasCompleted {
                    hasCompleted = true
                    action()
                    return true
                }
                return false
            }

            // 设置超时
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if checkAndResume({
                    connection.cancel()
                    continuation.resume(
                        throwing: NSError(
                            domain: "NativeTCPClient",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "请求超时（\(Int(timeout))秒）"]
                        ))
                }) {
                }
            }

            connection.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }

                switch state {
                case .ready:
                    // 发送请求（包含长度前缀）
                    var requestWithLength = Data()
                    let length = UInt32(requestData.count).bigEndian
                    requestWithLength.append(contentsOf: withUnsafeBytes(of: length) { Data($0) })
                    requestWithLength.append(requestData)

                    connection.send(
                        content: requestWithLength,
                        completion: .contentProcessed { [weak self] error in
                            if let error = error {
                                if checkAndResume({
                                    timeoutTask.cancel()
                                    continuation.resume(throwing: error)
                                }) {
                                    connection.cancel()
                                }
                                return
                            }

                            // 接收响应
                            guard let self = self else { return }
                            self.receiveResponse(from: connection) { result in
                                if checkAndResume({
                                    timeoutTask.cancel()
                                    switch result {
                                    case .success(let data):
                                        continuation.resume(returning: data)
                                    case .failure(let error):
                                        continuation.resume(throwing: error)
                                    }
                                }) {
                                    connection.cancel()
                                }
                            }
                        })

                case .waiting:
                    // 等待状态不立即失败，超时机制会处理
                    break

                case .preparing:
                    // 准备状态，继续等待
                    break

                case .failed(let error):
                    if checkAndResume({
                        timeoutTask.cancel()
                        continuation.resume(throwing: error)
                    }) {
                        connection.cancel()
                    }

                case .cancelled:
                    if checkAndResume({
                        timeoutTask.cancel()
                        continuation.resume(
                            throwing: NSError(
                                domain: "NativeTCPClient",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "连接已取消"]
                            ))
                    }) {
                    }

                default:
                    break
                }
            }

            connection.start(queue: self.queue)
        }
    }

    /// 接收响应（带长度前缀）
    private func receiveResponse(
        from connection: NWConnection, completion: @escaping (Result<Data, Error>) -> Void
    ) {
        // 先接收长度（4 字节）
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) {
            data, _, isComplete, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let lengthData = data, lengthData.count == 4 else {
                completion(
                    .failure(
                        NSError(
                            domain: "NativeTCPClient", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "无法接收长度"])))
                return
            }

            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            guard length > 0 && length <= 100 * 1024 * 1024 else {  // 最大100MB
                completion(
                    .failure(
                        NSError(
                            domain: "NativeTCPClient", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "响应长度异常: \(length)"])))
                return
            }

            // 接收实际数据
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) {
                data, _, isComplete, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }

                guard let responseData = data, responseData.count == Int(length) else {
                    completion(
                        .failure(
                            NSError(
                                domain: "NativeTCPClient", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "无法接收完整响应"])))
                    return
                }

                completion(.success(responseData))
            }
        }
    }
}
