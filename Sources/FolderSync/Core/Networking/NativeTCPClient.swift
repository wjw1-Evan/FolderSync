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
        let components = address.split(separator: ":")
        guard components.count == 2,
              let host = String(components[0]).removingPercentEncoding,
              let portString = String(components[1]).removingPercentEncoding,
              let port = UInt16(portString),
              port > 0 else {
            throw NSError(domain: "NativeTCPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的地址格式或端口为0: \(address)"])
        }
        
        // 编码请求
        let requestData = try JSONEncoder().encode(message)
        
        // 创建连接
        let hostEndpoint = NWEndpoint.Host(host)
        let portEndpoint = NWEndpoint.Port(rawValue: port)!
        let endpoint = NWEndpoint.hostPort(host: hostEndpoint, port: portEndpoint)
        
        let parameters = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: parameters)
        
        return try await withCheckedThrowingContinuation { continuation in
            var hasCompleted = false
            
            // 设置超时
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !hasCompleted {
                    hasCompleted = true
                    connection.cancel()
                    continuation.resume(throwing: NSError(
                        domain: "NativeTCPClient",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "请求超时"]
                    ))
                }
            }
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // 发送请求（包含长度前缀）
                    var requestWithLength = Data()
                    let length = UInt32(requestData.count).bigEndian
                    requestWithLength.append(contentsOf: withUnsafeBytes(of: length) { Data($0) })
                    requestWithLength.append(requestData)
                    
                    connection.send(content: requestWithLength, completion: .contentProcessed { error in
                        if let error = error {
                            if !hasCompleted {
                                hasCompleted = true
                                timeoutTask.cancel()
                                continuation.resume(throwing: error)
                            }
                            connection.cancel()
                            return
                        }
                        
                        // 接收响应
                        self.receiveResponse(from: connection) { result in
                            if !hasCompleted {
                                hasCompleted = true
                                timeoutTask.cancel()
                                switch result {
                                case .success(let data):
                                    continuation.resume(returning: data)
                                case .failure(let error):
                                    continuation.resume(throwing: error)
                                }
                            }
                            connection.cancel()
                        }
                    })
                    
                case .failed(let error):
                    if !hasCompleted {
                        hasCompleted = true
                        timeoutTask.cancel()
                        continuation.resume(throwing: error)
                    }
                    connection.cancel()
                    
                case .cancelled:
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
                    break
                }
            }
            
            connection.start(queue: self.queue)
        }
    }
    
    /// 接收响应（带长度前缀）
    private func receiveResponse(from connection: NWConnection, completion: @escaping (Result<Data, Error>) -> Void) {
        // 先接收长度（4 字节）
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, isComplete, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let lengthData = data, lengthData.count == 4 else {
                completion(.failure(NSError(domain: "NativeTCPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法接收长度"])))
                return
            }
            
            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            
            // 接收实际数据
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { data, _, isComplete, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }
                
                guard let responseData = data, responseData.count == Int(length) else {
                    completion(.failure(NSError(domain: "NativeTCPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法接收完整响应"])))
                    return
                }
                
                completion(.success(responseData))
            }
        }
    }
}
