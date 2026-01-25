import Foundation
import Network

/// 原生 TCP 服务器 - 用于接收对等点请求
public class NativeTCPServer {
    private var listener: NWListener?
    private var isRunning = false
    private let queue = DispatchQueue(label: "com.foldersync.nativetcp.server")
    
    /// 消息处理回调：SyncRequest -> SyncResponse
    public var messageHandler: ((SyncRequest) async throws -> SyncResponse)?
    
    public init() {}
    
    /// 启动服务器
    /// - Parameter port: 监听端口（0 表示自动分配）
    /// - Returns: 实际监听的端口
    public func start(port: UInt16 = 0) throws -> UInt16 {
        guard !isRunning else {
            throw NSError(domain: "NativeTCPServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务器已在运行"])
        }
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        let portEndpoint = port == 0 ? nil : NWEndpoint.Port(rawValue: port)
        let listener = try NWListener(using: parameters, on: portEndpoint ?? NWEndpoint.Port(rawValue: 0)!)
        
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port {
                    print("[NativeTCPServer] ✅ 服务器已启动，监听端口: \(port.rawValue)")
                }
            case .failed(let error):
                print("[NativeTCPServer] ❌ 服务器失败: \(error)")
            default:
                break
            }
        }
        
        listener.start(queue: queue)
        self.listener = listener
        self.isRunning = true
        
        // 获取实际端口
        // 等待监听器就绪，最多等待2秒
        var attempts = 0
        while attempts < 20 {
            if let actualPort = listener.port, actualPort.rawValue > 0 {
                return actualPort.rawValue
            }
            Thread.sleep(forTimeInterval: 0.1)
            attempts += 1
        }
        
        // 如果仍然无法获取端口，抛出错误
        throw NSError(domain: "NativeTCPServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法获取服务器监听端口"])
    }
    
    /// 停止服务器
    public func stop() {
        isRunning = false
        listener?.cancel()
        listener = nil
    }
    
    /// 获取监听端口
    public var listeningPort: UInt16? {
        guard let port = listener?.port?.rawValue, port > 0 else {
            return nil
        }
        return port
    }
    
    /// 处理连接
    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.receiveRequest(from: connection)
            case .failed(let error):
                print("[NativeTCPServer] 连接失败: \(error)")
                connection.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
    
    /// 接收请求（带长度前缀）
    private func receiveRequest(from connection: NWConnection) {
        // 先接收长度（4 字节）
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }
            
            if let error = error {
                print("[NativeTCPServer] 接收长度失败: \(error)")
                connection.cancel()
                return
            }
            
            guard let lengthData = data, lengthData.count == 4 else {
                print("[NativeTCPServer] 无法接收长度")
                connection.cancel()
                return
            }
            
            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            
            // 接收实际数据
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] data, _, isComplete, error in
                guard let self = self else {
                    connection.cancel()
                    return
                }
                
                if let error = error {
                    print("[NativeTCPServer] 接收数据失败: \(error)")
                    connection.cancel()
                    return
                }
                
                guard let requestData = data, requestData.count == Int(length) else {
                    print("[NativeTCPServer] 无法接收完整请求")
                    connection.cancel()
                    return
                }
                
                // 处理请求
                Task {
                    await self.processRequest(requestData, connection: connection)
                }
            }
        }
    }
    
    /// 处理请求
    private func processRequest(_ requestData: Data, connection: NWConnection) async {
        do {
            // 解码请求
            let request = try JSONDecoder().decode(SyncRequest.self, from: requestData)
            
            // 调用处理回调
            guard let handler = messageHandler else {
                print("[NativeTCPServer] ⚠️ 消息处理器未设置")
                let errorResponse = SyncResponse.error("消息处理器未设置")
                await sendResponse(errorResponse, to: connection)
                return
            }
            
            let response = try await handler(request)
            
            // 发送响应
            await sendResponse(response, to: connection)
            
        } catch {
            print("[NativeTCPServer] ❌ 处理请求失败: \(error)")
            let errorResponse = SyncResponse.error("处理请求失败: \(error.localizedDescription)")
            await sendResponse(errorResponse, to: connection)
        }
    }
    
    /// 发送响应（带长度前缀）
    private func sendResponse(_ response: SyncResponse, to connection: NWConnection) async {
        do {
            let responseData = try JSONEncoder().encode(response)
            
            // 添加长度前缀
            var responseWithLength = Data()
            let length = UInt32(responseData.count).bigEndian
            responseWithLength.append(contentsOf: withUnsafeBytes(of: length) { Data($0) })
            responseWithLength.append(responseData)
            
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: responseWithLength, completion: .contentProcessed { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                    connection.cancel()
                })
            }
        } catch {
            print("[NativeTCPServer] ❌ 发送响应失败: \(error)")
            connection.cancel()
        }
    }
}
