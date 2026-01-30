import Foundation
import Network

/// AutoNAT 服务 - 自动检测 NAT 类型和公网可达性
public class AutoNAT {
    private let queue = DispatchQueue(label: "com.foldersync.autonat")
    
    public enum NATType {
        case unknown
        case publicIP // 公网 IP，可直接访问
        case symmetricNAT // 对称 NAT，难以穿透
        case portRestrictedCone // 端口限制锥形 NAT
        case restrictedCone // 限制锥形 NAT
        case fullCone // 全锥形 NAT，较易穿透
    }
    
    public var natType: NATType = .unknown
    public var publicIP: String?
    public var isReachable: Bool = false
    
    public init() {}
    
    /// 执行 NAT 检测
    /// - Parameter testServers: 用于检测的服务器列表（STUN 服务器）
    public func detectNAT(testServers: [String] = []) async {
        // 如果没有提供测试服务器，使用默认的 STUN 服务器
        let servers = testServers.isEmpty ? [
            "stun.l.google.com:19302",
            "stun1.l.google.com:19302"
        ] : testServers
        
        // 简化实现：尝试连接到外部服务器检测 NAT 类型
        // 完整实现需要使用 STUN 协议
        
        for server in servers {
            let components = server.split(separator: ":")
            guard components.count == 2,
                  let port = UInt16(components[1]) else {
                continue
            }
            
            let host = String(components[0])
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            let parameters = NWParameters.udp
            
            let connection = NWConnection(to: endpoint, using: parameters)
            
            final class DetectedState {
                private let lock = NSLock()
                private var value = false
                
                func set() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    let wasSet = value
                    if !wasSet {
                        value = true
                    }
                    return wasSet
                }
                
                func get() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    return value
                }
            }
            
            let detectedState = DetectedState()
            
            connection.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                
                switch state {
                case .ready:
                    // 连接成功，可能是公网 IP 或全锥形 NAT
                    self.isReachable = true
                    self.natType = .fullCone
                    connection.cancel()
                    _ = detectedState.set()
                    
                case .failed:
                    // 连接失败，可能是对称 NAT 或其他类型
                    let wasDetected = detectedState.set()
                    if !wasDetected {
                        self.natType = .symmetricNAT
                        self.isReachable = false
                    }
                    connection.cancel()
                    
                default:
                    break
                }
            }
            
            connection.start(queue: queue)
            
            // 等待检测完成（最多 5 秒）
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            
            if detectedState.get() {
                break
            }
            
            connection.cancel()
        }
        
        AppLogger.syncPrint("[AutoNAT] NAT 类型: \(natType), 可达性: \(isReachable)")
    }
    
    /// 获取本机公网 IP（通过 STUN 服务器）
    public func getPublicIP() async -> String? {
        // 简化实现：实际应该使用 STUN 协议获取
        // 这里返回 nil，表示需要完整实现
        return nil
    }
}
