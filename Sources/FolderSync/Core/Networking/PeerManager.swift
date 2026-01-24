import Foundation
import LibP2P
import NIOCore

/// Peer 信息模型
public struct PeerInfo {
    public let peerID: PeerID
    public let peerIDString: String
    public var addresses: [Multiaddr]
    public var isRegistered: Bool
    public var isOnline: Bool
    public var discoveryTime: Date
    public var lastSeenTime: Date
    
    public init(peerID: PeerID, addresses: [Multiaddr] = [], isRegistered: Bool = false, isOnline: Bool = false) {
        self.peerID = peerID
        self.peerIDString = peerID.b58String
        self.addresses = addresses
        self.isRegistered = isRegistered
        self.isOnline = isOnline
        self.discoveryTime = Date()
        self.lastSeenTime = Date()
    }
    
    /// 更新地址
    mutating func updateAddresses(_ newAddresses: [Multiaddr]) {
        let oldSet = Set(self.addresses.map { $0.description })
        let newSet = Set(newAddresses.map { $0.description })
        if oldSet != newSet {
            self.addresses = newAddresses
            self.lastSeenTime = Date()
        }
    }
    
    /// 更新在线状态
    mutating func updateOnlineStatus(_ online: Bool) {
        if self.isOnline != online {
            self.isOnline = online
            if online {
                self.lastSeenTime = Date()
            }
        }
    }
    
    /// 标记为已注册
    mutating func markAsRegistered() {
        self.isRegistered = true
        self.lastSeenTime = Date()
    }
}

/// 统一的 Peer 管理器
@MainActor
public class PeerManager: ObservableObject {
    /// 所有已知的 Peer（PeerID String -> PeerInfo）
    @Published private(set) var peers: [String: PeerInfo] = [:]
    
    /// 正在注册的 Peer ID 集合（用于去重）
    private var registeringPeerIDs: Set<String> = []
    
    /// 线程安全的队列，用于处理并发访问
    private let queue = DispatchQueue(label: "com.foldersync.peermanager", attributes: .concurrent)
    
    public init() {}
    
    // MARK: - 查询方法
    
    /// 获取所有 Peer 列表
    public var allPeers: [PeerInfo] {
        return Array(peers.values)
    }
    
    /// 获取在线 Peer 列表
    public var onlinePeers: [PeerInfo] {
        return peers.values.filter { $0.isOnline }
    }
    
    /// 获取离线 Peer 列表
    public var offlinePeers: [PeerInfo] {
        return peers.values.filter { !$0.isOnline }
    }
    
    /// 根据 PeerID 获取 Peer 信息
    public func getPeer(_ peerIDString: String) -> PeerInfo? {
        return peers[peerIDString]
    }
    
    /// 根据 PeerID 对象获取 Peer 信息
    public func getPeer(_ peerID: PeerID) -> PeerInfo? {
        return peers[peerID.b58String]
    }
    
    /// 检查 Peer 是否存在
    public func hasPeer(_ peerIDString: String) -> Bool {
        return peers[peerIDString] != nil
    }
    
    /// 检查 Peer 是否正在注册
    public func isRegistering(_ peerIDString: String) -> Bool {
        return queue.sync {
            return registeringPeerIDs.contains(peerIDString)
        }
    }
    
    /// 检查 Peer 是否已注册
    public func isRegistered(_ peerIDString: String) -> Bool {
        return peers[peerIDString]?.isRegistered ?? false
    }
    
    /// 检查 Peer 是否在线
    public func isOnline(_ peerIDString: String) -> Bool {
        return peers[peerIDString]?.isOnline ?? false
    }
    
    /// 获取 Peer 的地址
    public func getAddresses(for peerIDString: String) -> [Multiaddr] {
        return peers[peerIDString]?.addresses ?? []
    }
    
    /// 获取设备统计
    public var deviceCounts: (online: Int, offline: Int) {
        let online = onlinePeers.count
        let offline = offlinePeers.count
        return (online, offline)
    }
    
    // MARK: - 更新方法
    
    /// 添加或更新 Peer
    @discardableResult
    public func addOrUpdatePeer(_ peerID: PeerID, addresses: [Multiaddr] = []) -> PeerInfo {
        let peerIDString = peerID.b58String
        
        if var existing = peers[peerIDString] {
            // 更新现有 Peer
            // 只有当新地址不为空时才更新地址，避免用空数组覆盖已有地址
            if !addresses.isEmpty {
                existing.updateAddresses(addresses)
            }
            peers[peerIDString] = existing
            return existing
        } else {
            // 添加新 Peer
            var newPeer = PeerInfo(peerID: peerID, addresses: addresses)
            peers[peerIDString] = newPeer
            return newPeer
        }
    }
    
    /// 更新 Peer 地址
    public func updateAddresses(_ peerIDString: String, addresses: [Multiaddr]) {
        guard var peer = peers[peerIDString] else { return }
        peer.updateAddresses(addresses)
        peers[peerIDString] = peer
    }
    
    /// 标记 Peer 为已注册
    public func markAsRegistered(_ peerIDString: String) {
        guard var peer = peers[peerIDString] else { return }
        peer.markAsRegistered()
        peers[peerIDString] = peer
    }
    
    /// 更新 Peer 在线状态
    public func updateOnlineStatus(_ peerIDString: String, isOnline: Bool) {
        guard var peer = peers[peerIDString] else { return }
        peer.updateOnlineStatus(isOnline)
        peers[peerIDString] = peer
    }
    
    /// 标记 Peer 为正在注册（用于去重）
    public func startRegistering(_ peerIDString: String) -> Bool {
        return queue.sync(flags: .barrier) {
            if registeringPeerIDs.contains(peerIDString) {
                return false
            }
            registeringPeerIDs.insert(peerIDString)
            return true
        }
    }
    
    /// 标记 Peer 注册完成
    public func finishRegistering(_ peerIDString: String) {
        queue.async(flags: .barrier) {
            self.registeringPeerIDs.remove(peerIDString)
        }
    }
    
    /// 移除 Peer
    public func removePeer(_ peerIDString: String) {
        peers.removeValue(forKey: peerIDString)
        queue.async(flags: .barrier) {
            self.registeringPeerIDs.remove(peerIDString)
        }
    }
    
    /// 清除所有 Peer
    public func clearAll() {
        peers.removeAll()
        queue.async(flags: .barrier) {
            self.registeringPeerIDs.removeAll()
        }
    }
    
    /// 更新所有 Peer 的最后可见时间
    public func updateLastSeen(_ peerIDString: String) {
        guard var peer = peers[peerIDString] else { return }
        peer.lastSeenTime = Date()
        peers[peerIDString] = peer
    }
}
