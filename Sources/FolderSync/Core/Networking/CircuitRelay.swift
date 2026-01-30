import Foundation
import Network

/// Circuit Relay 中继服务 - 用于 NAT 穿透失败时的中继通信
public class CircuitRelay {
    private var relayServers: [RelayServer] = []
    private let queue = DispatchQueue(label: "com.foldersync.circuitrelay")
    
    public struct RelayServer {
        let peerID: String
        let address: String // IP:Port
        let isPublic: Bool // 是否为公网服务器
    }
    
    public init() {}
    
    /// 注册中继服务器
    public func registerRelayServer(peerID: String, address: String, isPublic: Bool = false) {
        let server = RelayServer(peerID: peerID, address: address, isPublic: isPublic)
        if !relayServers.contains(where: { $0.peerID == peerID }) {
            relayServers.append(server)
            AppLogger.syncPrint("[CircuitRelay] ✅ 注册中继服务器: \(peerID.prefix(12))... @ \(address)")
        }
    }
    
    /// 移除中继服务器
    public func removeRelayServer(peerID: String) {
        relayServers.removeAll { $0.peerID == peerID }
    }
    
    /// 获取可用的中继服务器列表
    public func getAvailableRelays() -> [RelayServer] {
        return relayServers
    }
    
    /// 通过中继服务器建立连接
    /// - Parameters:
    ///   - relayPeerID: 中继服务器的 PeerID
    ///   - targetPeerID: 目标 PeerID
    ///   - message: 要发送的消息
    /// - Returns: 响应数据
    public func relayMessage(relayPeerID: String, targetPeerID: String, message: Data) async throws -> Data {
        guard let relay = relayServers.first(where: { $0.peerID == relayPeerID }) else {
            throw NSError(domain: "CircuitRelay", code: -1, userInfo: [NSLocalizedDescriptionKey: "中继服务器不存在"])
        }
        
        // 解析中继服务器地址
        let components = relay.address.split(separator: ":")
        guard components.count == 2,
              let port = UInt16(components[1]) else {
            throw NSError(domain: "CircuitRelay", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的中继服务器地址"])
        }
        
        let host = String(components[0])
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let parameters = NWParameters.tcp
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
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // 发送中继请求：包含目标 PeerID 和消息
                    let relayRequest = RelayRequest(targetPeerID: targetPeerID, data: message)
                    if let requestData = try? JSONEncoder().encode(relayRequest) {
                            connection.send(content: requestData, completion: .contentProcessed { error in
                            if let error = error {
                                if checkAndResume({ continuation.resume(throwing: error) }) {
                                    connection.cancel()
                                }
                                return
                            }
                            
                            // 接收响应
                            connection.receive(minimumIncompleteLength: 1, maximumLength: 10 * 1024 * 1024) { data, _, isComplete, error in
                                if let error = error {
                                    if checkAndResume({ continuation.resume(throwing: error) }) {
                                        connection.cancel()
                                    }
                                    return
                                }
                                
                                if let data = data, !data.isEmpty {
                                    if checkAndResume({ continuation.resume(returning: data) }) {
                                        connection.cancel()
                                    }
                                } else if isComplete {
                                    if checkAndResume({ continuation.resume(throwing: NSError(domain: "CircuitRelay", code: -1, userInfo: [NSLocalizedDescriptionKey: "连接已关闭"])) }) {
                                        connection.cancel()
                                    }
                                }
                            }
                        })
                    }
                    
                case .failed(let error):
                    if checkAndResume({ continuation.resume(throwing: error) }) {
                        connection.cancel()
                    }
                    
                default:
                    break
                }
            }
            
            connection.start(queue: queue)
            
            // 设置超时（30秒）
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if checkAndResume({ continuation.resume(throwing: NSError(domain: "CircuitRelay", code: -1, userInfo: [NSLocalizedDescriptionKey: "中继请求超时"])) }) {
                    connection.cancel()
                }
            }
        }
    }
    
    /// 中继请求结构
    private struct RelayRequest: Codable {
        let targetPeerID: String
        let data: Data
    }
}
