import Foundation
import LibP2P
import NIOCore

/// Peer 注册状态
public enum PeerRegistrationState {
    case notRegistered      // 未注册
    case registering        // 正在注册
    case registered         // 已注册到 libp2p peer store
    case failed(String)     // 注册失败（带错误信息）
}

/// Peer 注册服务 - 统一管理 libp2p peer 注册
@MainActor
public class PeerRegistrationService: ObservableObject {
    /// 注册状态：peerID -> 状态
    @Published private(set) var registrationStates: [String: PeerRegistrationState] = [:]
    
    /// libp2p discovery handler（用于注册 peer）
    private var discoveryHandler: ((LibP2P.PeerInfo) -> Void)?
    
    /// 注册队列：避免并发注册同一个 peer
    private var registeringPeerIDs: Set<String> = []
    
    /// 线程安全的队列
    private let queue = DispatchQueue(label: "com.foldersync.peerregistration", attributes: .concurrent)
    
    /// 初始化
    public init() {}
    
    /// 设置 libp2p discovery handler
    public func setDiscoveryHandler(_ handler: @escaping (LibP2P.PeerInfo) -> Void) {
        self.discoveryHandler = handler
        print("[PeerRegistrationService] ✅ 已设置 discovery handler")
    }
    
    /// 检查 discovery handler 是否已设置
    public var isReady: Bool {
        return discoveryHandler != nil
    }
    
    /// 注册 peer 到 libp2p peer store
    /// - Parameters:
    ///   - peerID: PeerID 对象
    ///   - addresses: 地址列表
    /// - Returns: 是否成功启动注册（如果已经在注册中，返回 false）
    @discardableResult
    public func registerPeer(peerID: PeerID, addresses: [Multiaddr]) -> Bool {
        let peerIDString = peerID.b58String
        
        // 检查是否正在注册
        let isRegistering = queue.sync {
            if registeringPeerIDs.contains(peerIDString) {
                return true
            }
            registeringPeerIDs.insert(peerIDString)
            return false
        }
        
        if isRegistering {
            print("[PeerRegistrationService] ⏭️ Peer 正在注册中，跳过: \(peerIDString.prefix(12))...")
            return false
        }
        
        // 检查 discovery handler
        guard let handler = discoveryHandler else {
            print("[PeerRegistrationService] ⚠️ Discovery handler 未设置，无法注册: \(peerIDString.prefix(12))...")
            queue.async(flags: .barrier) {
                self.registeringPeerIDs.remove(peerIDString)
            }
            registrationStates[peerIDString] = .failed("Discovery handler 未设置")
            return false
        }
        
        // 检查地址
        guard !addresses.isEmpty else {
            print("[PeerRegistrationService] ⚠️ 地址列表为空，无法注册: \(peerIDString.prefix(12))...")
            queue.async(flags: .barrier) {
                self.registeringPeerIDs.remove(peerIDString)
            }
            registrationStates[peerIDString] = .failed("地址列表为空")
            return false
        }
        
        // 更新状态为正在注册
        registrationStates[peerIDString] = .registering
        
        // 执行注册
        let libp2pPeerInfo = LibP2P.PeerInfo(peer: peerID, addresses: addresses)
        handler(libp2pPeerInfo)
        
        // 标记为已注册
        registrationStates[peerIDString] = .registered
        
        // 从注册队列中移除
        queue.async(flags: .barrier) {
            self.registeringPeerIDs.remove(peerIDString)
        }
        
        print("[PeerRegistrationService] ✅ 已注册 peer: \(peerIDString.prefix(12))... (\(addresses.count) 个地址)")
        return true
    }
    
    /// 批量注册 peer（用于启动时预注册）
    public func registerPeers(_ peers: [(peerID: PeerID, addresses: [Multiaddr])]) {
        guard let handler = discoveryHandler else {
            print("[PeerRegistrationService] ⚠️ Discovery handler 未设置，无法批量注册")
            return
        }
        
        guard !peers.isEmpty else {
            print("[PeerRegistrationService] ℹ️ 没有需要注册的 peer")
            return
        }
        
        print("[PeerRegistrationService] 🔄 开始批量注册 \(peers.count) 个 peer...")
        
        for (peerID, addresses) in peers {
            let peerIDString = peerID.b58String
            
            // 跳过正在注册的
            let isRegistering = queue.sync {
                return registeringPeerIDs.contains(peerIDString)
            }
            
            if isRegistering {
                continue
            }
            
            // 检查地址
            guard !addresses.isEmpty else {
                print("[PeerRegistrationService] ⚠️ 跳过无地址的 peer: \(peerIDString.prefix(12))...")
                continue
            }
            
            // 标记为正在注册
            queue.async(flags: .barrier) {
                self.registeringPeerIDs.insert(peerIDString)
            }
            registrationStates[peerIDString] = .registering
            
            // 执行注册
            let libp2pPeerInfo = LibP2P.PeerInfo(peer: peerID, addresses: addresses)
            handler(libp2pPeerInfo)
            
            // 标记为已注册
            registrationStates[peerIDString] = .registered
            
            // 从注册队列中移除
            queue.async(flags: .barrier) {
                self.registeringPeerIDs.remove(peerIDString)
            }
            
            print("[PeerRegistrationService] ✅ 已注册 peer: \(peerIDString.prefix(12))... (\(addresses.count) 个地址)")
        }
        
        print("[PeerRegistrationService] ✅ 完成批量注册 \(peers.count) 个 peer")
    }
    
    /// 重试注册（用于 peerNotFound 错误后）
    public func retryRegistration(peerID: PeerID, addresses: [Multiaddr]) -> Bool {
        let peerIDString = peerID.b58String
        
        // 清除之前的失败状态
        if case .failed = registrationStates[peerIDString] {
            registrationStates[peerIDString] = .notRegistered
        }
        
        return registerPeer(peerID: peerID, addresses: addresses)
    }
    
    /// 获取注册状态
    public func getRegistrationState(_ peerIDString: String) -> PeerRegistrationState {
        return registrationStates[peerIDString] ?? .notRegistered
    }
    
    /// 检查是否已注册
    public func isRegistered(_ peerIDString: String) -> Bool {
        if case .registered = registrationStates[peerIDString] {
            return true
        }
        return false
    }
    
    /// 清除注册状态（用于测试或重置）
    public func clearRegistrationState(_ peerIDString: String) {
        registrationStates.removeValue(forKey: peerIDString)
        queue.async(flags: .barrier) {
            self.registeringPeerIDs.remove(peerIDString)
        }
    }
}
