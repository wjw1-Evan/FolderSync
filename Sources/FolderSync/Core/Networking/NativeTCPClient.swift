import Foundation
import Network

/// 原生 TCP 客户端 - 用于与对等点通信
public class NativeTCPClient {
    private let queue = DispatchQueue(label: "com.foldersync.nativetcp.client", attributes: .concurrent)
    
    public init() {}
    
    /// 发送请求到对等点
    /// - Parameters:
    ///   - message: 同步请求消息
    ///   - address: 对等点地址（格式：ip:port）
    ///   - timeout: 超时时间（秒）
    /// - Returns: 响应数据
    public func sendRequest(_ message: SyncRequest, to address: String, timeout: TimeInterval = 30.0) async throws -> Data {
        // 解析地址
        print("[NativeTCPClient] 🔍 解析地址: \(address)")
        let components = address.split(separator: ":")
        guard components.count == 2 else {
            print("[NativeTCPClient] ❌ 地址格式错误: 期望 'IP:Port'，实际: \(address)")
            throw NSError(domain: "NativeTCPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的地址格式: \(address) (期望格式: IP:Port)"])
        }
        
        let host = String(components[0]).removingPercentEncoding ?? String(components[0])
        let portString = String(components[1]).removingPercentEncoding ?? String(components[1])
        
        guard let port = UInt16(portString), port > 0, port <= 65535 else {
            print("[NativeTCPClient] ❌ 端口无效: '\(portString)' (范围: 1-65535)")
            throw NSError(domain: "NativeTCPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的端口: \(portString) (地址: \(address))"])
        }
        
        print("[NativeTCPClient] ✅ 地址解析成功: IP=\(host), 端口=\(port)")
        
        // 编码请求
        let requestData = try JSONEncoder().encode(message)
        
        print("[NativeTCPClient] 🔗 开始连接到: \(host):\(port)")
        
        // 创建连接
        let hostEndpoint = NWEndpoint.Host(host)
        let portEndpoint = NWEndpoint.Port(rawValue: port)!
        let endpoint = NWEndpoint.hostPort(host: hostEndpoint, port: portEndpoint)
        
        let parameters = NWParameters.tcp
        // 设置连接参数
        parameters.allowLocalEndpointReuse = true
        // 不限制接口类型，允许使用任何可用网络
        let connection = NWConnection(to: endpoint, using: parameters)
        
        return try await withCheckedThrowingContinuation { continuation in
            var hasCompleted = false
            
            // 设置超时
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !hasCompleted {
                    hasCompleted = true
                    print("[NativeTCPClient] ⏱️ 连接超时: \(address) (超时时间: \(timeout)秒)")
                    connection.cancel()
                    continuation.resume(throwing: NSError(
                        domain: "NativeTCPClient",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "请求超时（\(Int(timeout))秒）"]
                    ))
                }
            }
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[NativeTCPClient] ✅ 连接已就绪: \(address)")
                    // 发送请求（包含长度前缀）
                    var requestWithLength = Data()
                    let length = UInt32(requestData.count).bigEndian
                    requestWithLength.append(contentsOf: withUnsafeBytes(of: length) { Data($0) })
                    requestWithLength.append(requestData)
                    
                    connection.send(content: requestWithLength, completion: .contentProcessed { error in
                        if let error = error {
                            print("[NativeTCPClient] ❌ 发送请求失败: \(error)")
                            if !hasCompleted {
                                hasCompleted = true
                                timeoutTask.cancel()
                                continuation.resume(throwing: error)
                            }
                            connection.cancel()
                            return
                        }
                        
                        print("[NativeTCPClient] 📤 请求已发送，等待响应...")
                        // 接收响应
                        self.receiveResponse(from: connection) { result in
                            if !hasCompleted {
                                hasCompleted = true
                                timeoutTask.cancel()
                                switch result {
                                case .success(let data):
                                    print("[NativeTCPClient] ✅ 收到响应，大小: \(data.count) 字节")
                                    continuation.resume(returning: data)
                                case .failure(let error):
                                    print("[NativeTCPClient] ❌ 接收响应失败: \(error)")
                                    continuation.resume(throwing: error)
                                }
                            }
                            connection.cancel()
                        }
                    })
                    
                case .waiting(let error):
                    print("[NativeTCPClient] ⏳ 连接等待中: \(address), 错误: \(error)")
                    // 等待状态不立即失败，但记录日志
                    // 如果等待时间过长，超时机制会处理
                    // 注意：waiting 状态可能持续很长时间，超时机制会在 timeout 秒后取消连接
                    
                case .preparing:
                    print("[NativeTCPClient] 🔄 连接准备中: \(address)")
                    // 准备状态，继续等待
                    
                case .failed(let error):
                    print("[NativeTCPClient] ❌ 连接失败: \(address), 错误: \(error)")
                    if !hasCompleted {
                        hasCompleted = true
                        timeoutTask.cancel()
                        continuation.resume(throwing: error)
                    }
                    connection.cancel()
                    
                case .cancelled:
                    print("[NativeTCPClient] ⚠️ 连接已取消: \(address)")
                    if !hasCompleted {
                        hasCompleted = true
                        timeoutTask.cancel()
                        continuation.resume(throwing: NSError(
                            domain: "NativeTCPClient",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "连接已取消"]
                        ))
                    }
                    
                default:
                    print("[NativeTCPClient] ℹ️ 连接状态: \(state), 地址: \(address)")
                    break
                }
            }
            
            connection.start(queue: self.queue)
        }
    }
    
    /// 接收响应（带长度前缀）
    private func receiveResponse(from connection: NWConnection, completion: @escaping (Result<Data, Error>) -> Void) {
        print("[NativeTCPClient] 📥 开始接收响应...")
        // 先接收长度（4 字节）
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, isComplete, error in
            if let error = error {
                print("[NativeTCPClient] ❌ 接收长度失败: \(error)")
                completion(.failure(error))
                return
            }
            
            guard let lengthData = data, lengthData.count == 4 else {
                print("[NativeTCPClient] ❌ 无法接收长度: data=\(data?.count ?? 0) 字节")
                completion(.failure(NSError(domain: "NativeTCPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法接收长度"])))
                return
            }
            
            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            print("[NativeTCPClient] 📏 响应长度: \(length) 字节")
            
            guard length > 0 && length <= 100 * 1024 * 1024 else { // 最大100MB
                print("[NativeTCPClient] ❌ 响应长度异常: \(length) 字节")
                completion(.failure(NSError(domain: "NativeTCPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "响应长度异常: \(length)"])))
                return
            }
            
            // 接收实际数据
            print("[NativeTCPClient] 📥 开始接收响应数据 (\(length) 字节)...")
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { data, _, isComplete, error in
                if let error = error {
                    print("[NativeTCPClient] ❌ 接收数据失败: \(error)")
                    completion(.failure(error))
                    return
                }
                
                guard let responseData = data, responseData.count == Int(length) else {
                    print("[NativeTCPClient] ❌ 无法接收完整响应: 期望 \(length) 字节，实际 \(data?.count ?? 0) 字节")
                    completion(.failure(NSError(domain: "NativeTCPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法接收完整响应"])))
                    return
                }
                
                print("[NativeTCPClient] ✅ 成功接收完整响应: \(responseData.count) 字节")
                completion(.success(responseData))
            }
        }
    }
}
