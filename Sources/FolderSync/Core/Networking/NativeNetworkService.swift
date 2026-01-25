import Foundation
import Network

/// 原生网络服务 - 替代 libp2p 的通信层
public class NativeNetworkService {
    private let tcpClient = NativeTCPClient()
    private var tcpServer: NativeTCPServer?
    private var listeningPort: UInt16?
    private let queue = DispatchQueue(label: "com.foldersync.nativenetwork", attributes: .concurrent)
    
    /// 消息处理回调
    public var messageHandler: ((SyncRequest) async throws -> SyncResponse)?
    
    public init() {}
    
    /// 启动 TCP 服务器
    /// - Parameter port: 监听端口（0 表示自动分配）
    /// - Returns: 实际监听的端口
    @discardableResult
    public func startServer(port: UInt16 = 0) throws -> UInt16 {
        let server = NativeTCPServer()
        server.messageHandler = { [weak self] request in
            guard let handler = self?.messageHandler else {
                return SyncResponse.error("消息处理器未设置")
            }
            return try await handler(request)
        }
        
        let actualPort = try server.start(port: port)
        guard actualPort > 0 else {
            throw NSError(domain: "NativeNetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务器启动失败：无法获取有效端口"])
        }
        self.tcpServer = server
        self.listeningPort = actualPort
        print("[NativeNetworkService] ✅ TCP 服务器已启动，端口: \(actualPort)")
        return actualPort
    }
    
    /// 停止服务器
    public func stopServer() {
        tcpServer?.stop()
        tcpServer = nil
        listeningPort = nil
        print("[NativeNetworkService] ✅ TCP 服务器已停止")
    }
    
    /// 获取监听端口
    /// 注意：只返回有效的端口（> 0），端口为0时返回nil
    public var serverPort: UInt16? {
        guard let port = listeningPort, port > 0 else {
            return nil
        }
        return port
    }
    
    /// 发送请求到对等点
    /// - Parameters:
    ///   - message: 同步请求
    ///   - address: 对等点地址（IP:Port 格式）
    ///   - timeout: 超时时间（秒）
    ///   - maxRetries: 最大重试次数
    /// - Returns: 响应
    public func sendRequest<T: Decodable>(
        _ message: SyncRequest,
        to address: String,
        timeout: TimeInterval = 30.0,
        maxRetries: Int = 3
    ) async throws -> T {
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                let responseData = try await tcpClient.sendRequest(message, to: address, timeout: timeout)
                let response = try JSONDecoder().decode(T.self, from: responseData)
                return response
            } catch {
                lastError = error
                let errorString = String(describing: error)
                let isTimeout = errorString.contains("超时") || errorString.contains("timeout")
                
                if isTimeout && attempt < maxRetries {
                    let backoffDelay = Double(attempt) * 2.0
                    print("[NativeNetworkService] ⚠️ 请求超时（尝试 \(attempt)/\(maxRetries)），等待 \(String(format: "%.1f", backoffDelay)) 秒后重试...")
                    try? await Task.sleep(nanoseconds: UInt64(backoffDelay * 1_000_000_000))
                    continue
                }
                
                if attempt == maxRetries {
                    throw lastError ?? error
                }
            }
        }
        
        throw lastError ?? NSError(
            domain: "NativeNetworkService",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "请求失败：未知错误"]
        )
    }
}
