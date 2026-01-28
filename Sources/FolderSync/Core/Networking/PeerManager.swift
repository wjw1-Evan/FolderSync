import Foundation

/// Peer 信息模型
public struct PeerInfo {
    public let peerID: PeerID
    public let peerIDString: String
    public var addresses: [Multiaddr]
    public var isRegistered: Bool
    public var isOnline: Bool
    public var discoveryTime: Date
    public var lastSeenTime: Date
    
    public init(peerID: PeerID, addresses: [Multiaddr] = [], isRegistered: Bool = false, isOnline: Bool = false, discoveryTime: Date? = nil, lastSeenTime: Date? = nil) {
        self.peerID = peerID
        self.peerIDString = peerID.b58String
        self.addresses = addresses
        self.isRegistered = isRegistered
        self.isOnline = isOnline
        self.discoveryTime = discoveryTime ?? Date()
        self.lastSeenTime = lastSeenTime ?? Date()
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

/// 设备状态
public enum DeviceStatus {
    case offline          // 离线
    case online           // 在线
    case connecting       // 连接中
    case disconnected     // 已断开
}

/// 统一的 Peer 管理器 - 管理所有已知设备
@MainActor
public class PeerManager: ObservableObject {
    /// 所有已知的 Peer（PeerID String -> PeerInfo）
    @Published private(set) var peers: [String: PeerInfo] = [:]
    
    /// 设备状态（PeerID String -> DeviceStatus）
    @Published private(set) var deviceStatuses: [String: DeviceStatus] = [:]
    
    /// 线程安全的队列，用于处理并发访问
    private let queue = DispatchQueue(label: "com.foldersync.peermanager", attributes: .concurrent)
    
    /// 持久化存储
    private let persistentStore = PersistentPeerStore.shared
    
    /// 保存防抖：避免频繁保存
    private var saveTask: Task<Void, Never>?
    private let saveDebounceDelay: TimeInterval = 2.0
    
    /// Peer 注册服务（可选，如果设置则自动同步注册状态）
    public weak var registrationService: PeerRegistrationService?
    
    public init() {
        // 从持久化存储加载 peer 信息
        loadPersistedPeers()
    }
    
    /// 从持久化存储加载 peer 信息
    private func loadPersistedPeers() {
        do {
            let persistentPeers = try persistentStore.loadPeers()
            for persistent in persistentPeers {
                if let (peerID, addresses, isRegistered) = persistentStore.convertToPeerInfo(persistent) {
                    // 恢复时间戳
                    let peerInfo = PeerInfo(
                        peerID: peerID,
                        addresses: addresses,
                        isRegistered: isRegistered,
                        isOnline: false, // 从持久化恢复时默认为离线，等待状态检查
                        discoveryTime: persistent.discoveryTime,
                        lastSeenTime: persistent.lastSeenTime
                    )
                    let peerIDString = peerID.b58String
                    peers[peerIDString] = peerInfo
                    // 初始化设备状态为离线（等待状态检查）
                    deviceStatuses[peerIDString] = .offline
                    print("[PeerManager] ✅ 已恢复 peer: \(peerIDString.prefix(12))... (已注册: \(isRegistered), 地址数: \(addresses.count))")
                }
            }
            if !persistentPeers.isEmpty {
                print("[PeerManager] ✅ 成功从持久化存储恢复 \(persistentPeers.count) 个 peer")
            }
        } catch {
            print("[PeerManager] ❌ 加载持久化 peer 失败: \(error)")
        }
    }
    
    /// 获取需要预注册到 libp2p 的 peer 列表（已注册但需要重新注册的）
    public func getPeersForPreRegistration() -> [(peerID: PeerID, addresses: [Multiaddr])] {
        return peers.values
            .filter { $0.isRegistered && !$0.addresses.isEmpty }
            .map { (peerID: $0.peerID, addresses: $0.addresses) }
    }
    
    /// 保存 peer 信息到持久化存储（带防抖）
    private func savePeersDebounced() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.saveDebounceDelay ?? 2.0) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.savePeers()
        }
    }
    
    /// 保存 peer 信息到持久化存储
    private func savePeers() async {
        do {
            try persistentStore.savePeers(peers)
        } catch {
            print("[PeerManager] ❌ 保存 peer 到持久化存储失败: \(error)")
        }
    }
    
    // MARK: - 查询方法
    
    /// 获取所有 Peer 列表
    public var allPeers: [PeerInfo] {
        return Array(peers.values)
    }
    
    /// 获取在线 Peer 列表（基于 deviceStatuses，这是权威状态源）
    public var onlinePeers: [PeerInfo] {
        return peers.values.filter { peerInfo in
            deviceStatuses[peerInfo.peerIDString] == .online
        }
    }
    
    /// 获取离线 Peer 列表（基于 deviceStatuses，这是权威状态源）
    /// 注意：只统计明确为 .offline 状态的 peer，不包括 .connecting 和 .disconnected
    public var offlinePeers: [PeerInfo] {
        return peers.values.filter { peerInfo in
            let status = deviceStatuses[peerInfo.peerIDString] ?? .offline
            return status == .offline
        }
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
        // 如果设置了 registrationService，使用它来检查
        if let registrationService = registrationService {
            let state = registrationService.getRegistrationState(peerIDString)
            if case .registering = state {
                return true
            }
        }
        return false
    }
    
    /// 检查 Peer 是否已注册
    public func isRegistered(_ peerIDString: String) -> Bool {
        // 优先从 registrationService 获取状态
        if let registrationService = registrationService {
            return registrationService.isRegistered(peerIDString)
        }
        return peers[peerIDString]?.isRegistered ?? false
    }
    
    /// 检查 Peer 是否在线
    public func isOnline(_ peerIDString: String) -> Bool {
        return deviceStatuses[peerIDString] == .online
    }
    
    /// 获取设备状态
    public func getDeviceStatus(_ peerIDString: String) -> DeviceStatus {
        return deviceStatuses[peerIDString] ?? .offline
    }
    
    /// 获取 Peer 的地址
    public func getAddresses(for peerIDString: String) -> [Multiaddr] {
        let addresses = peers[peerIDString]?.addresses ?? []
        // 移除日志输出，因为此方法会被频繁调用（同步过程中），避免日志重复
        return addresses
    }
    
    /// 获取设备统计
    public var deviceCounts: (online: Int, offline: Int) {
        var online = 0
        var offline = 0
        
        // 遍历所有 peers，统计在线和离线设备
        for peerInfo in peers.values {
            let status = deviceStatuses[peerInfo.peerIDString] ?? .offline
            if status == .online {
                online += 1
            } else if status == .offline {
                offline += 1
            }
            // 注意：.connecting 和 .disconnected 状态不统计到在线或离线中
            // 这样可以避免在连接过程中统计错误
        }
        
        return (online, offline)
    }
    
    // MARK: - 更新方法
    
    /// 添加或更新 Peer
    @discardableResult
    public func addOrUpdatePeer(_ peerID: PeerID, addresses: [Multiaddr] = []) -> PeerInfo {
        let peerIDString = peerID.b58String
        var shouldSave = false
        let isNewPeer = peers[peerIDString] == nil
        
        if var existing = peers[peerIDString] {
            // 更新现有 Peer
            let oldAddressCount = existing.addresses.count
            // 只有当新地址不为空时才更新地址，避免用空数组覆盖已有地址
            if !addresses.isEmpty {
                existing.updateAddresses(addresses)
                shouldSave = true
                print("[PeerManager] 🔄 [DEBUG] 更新现有 Peer: \(peerIDString.prefix(12))..., 旧地址数=\(oldAddressCount), 新地址数=\(addresses.count)")
            } else {
                print("[PeerManager] ℹ️ [DEBUG] Peer 已存在但地址为空，跳过更新: \(peerIDString.prefix(12))...")
            }
            // 注意：即使地址为空，收到广播也应该更新 lastSeenTime
            // 这表示设备仍然在线，只是地址可能暂时不可用
            // 但 updateAddresses 已经会更新 lastSeenTime（如果地址变化）
            // 如果地址没有变化，updateLastSeen 会在外部调用时更新
            peers[peerIDString] = existing
        } else {
            // 添加新 Peer
            let newPeer = PeerInfo(peerID: peerID, addresses: addresses)
            peers[peerIDString] = newPeer
            // 新 peer 默认状态为离线（除非后续明确设置为在线）
            if deviceStatuses[peerIDString] == nil {
                deviceStatuses[peerIDString] = .offline
            }
            shouldSave = true
            print("[PeerManager] ➕ [DEBUG] 添加新 Peer: \(peerIDString.prefix(12))..., 地址数=\(addresses.count), 初始状态=离线")
        }
        
        // 保存到持久化存储（带防抖）
        if shouldSave {
            savePeersDebounced()
        }
        
        return peers[peerIDString]!
    }
    
    /// 更新 Peer 地址
    public func updateAddresses(_ peerIDString: String, addresses: [Multiaddr]) {
        guard var peer = peers[peerIDString] else {
            print("[PeerManager] ⚠️ [DEBUG] 尝试更新不存在的 Peer 地址: \(peerIDString.prefix(12))...")
            return
        }
        let oldAddressSet = Set(peer.addresses.map { $0.description })
        let oldCount = peer.addresses.count
        peer.updateAddresses(addresses)
        peers[peerIDString] = peer
        
        // 如果地址发生变化，保存到持久化存储（带防抖）
        let newAddressSet = Set(peer.addresses.map { $0.description })
        if oldAddressSet != newAddressSet {
            print("[PeerManager] 🔄 [DEBUG] Peer 地址已更新: \(peerIDString.prefix(12))..., 旧地址数=\(oldCount), 新地址数=\(addresses.count)")
            savePeersDebounced()
        } else {
            print("[PeerManager] ℹ️ [DEBUG] Peer 地址未变化: \(peerIDString.prefix(12))...")
        }
    }
    
    /// 标记 Peer 为已注册
    public func markAsRegistered(_ peerIDString: String) {
        guard var peer = peers[peerIDString] else {
            print("[PeerManager] ⚠️ [DEBUG] 尝试标记不存在的 Peer 为已注册: \(peerIDString.prefix(12))...")
            return
        }
        let wasRegistered = peer.isRegistered
        peer.markAsRegistered()
        peers[peerIDString] = peer
        print("[PeerManager] ✅ [DEBUG] Peer 标记为已注册: \(peerIDString.prefix(12))..., 之前状态=\(wasRegistered ? "已注册" : "未注册")")
        // 保存到持久化存储（带防抖）
        savePeersDebounced()
    }
    
    /// 更新 Peer 在线状态
    public func updateOnlineStatus(_ peerIDString: String, isOnline: Bool) {
        guard var peer = peers[peerIDString] else {
            print("[PeerManager] ⚠️ [DEBUG] 尝试更新不存在的 Peer 在线状态: \(peerIDString.prefix(12))...")
            return
        }
        let oldStatus = peer.isOnline
        peer.updateOnlineStatus(isOnline)
        peers[peerIDString] = peer
        
        // 同步更新设备状态
        deviceStatuses[peerIDString] = isOnline ? .online : .offline
        
        if oldStatus != isOnline {
            print("[PeerManager] 🔄 [DEBUG] Peer 在线状态已更新: \(peerIDString.prefix(12))..., \(oldStatus ? "在线" : "离线") -> \(isOnline ? "在线" : "离线")")
        }
        
        // 保存到持久化存储（带防抖）
        savePeersDebounced()
    }
    
    /// 更新设备状态
    public func updateDeviceStatus(_ peerIDString: String, status: DeviceStatus) {
        let oldStatus = deviceStatuses[peerIDString]
        deviceStatuses[peerIDString] = status
        
        // 同步更新 PeerInfo 的在线状态
        if var peer = peers[peerIDString] {
            let isOnline = (status == .online)
            let oldOnlineStatus = peer.isOnline
            peer.updateOnlineStatus(isOnline)
            peers[peerIDString] = peer
            
            if oldStatus != status {
                let statusStr = {
                    switch status {
                    case .online: return "在线"
                    case .offline: return "离线"
                    case .connecting: return "连接中"
                    case .disconnected: return "已断开"
                    }
                }()
                print("[PeerManager] 🔄 [DEBUG] 设备状态已更新: \(peerIDString.prefix(12))..., \(oldStatus.map { "\($0)" } ?? "nil") -> \(statusStr)")
            }
        } else {
            print("[PeerManager] ⚠️ [DEBUG] 尝试更新不存在的设备状态: \(peerIDString.prefix(12))...")
        }
        
        // 保存到持久化存储（带防抖）
        savePeersDebounced()
    }
    
    /// 移除 Peer
    public func removePeer(_ peerIDString: String) {
        let existed = peers[peerIDString] != nil
        peers.removeValue(forKey: peerIDString)
        deviceStatuses.removeValue(forKey: peerIDString)
        if existed {
            print("[PeerManager] 🗑️ [DEBUG] 已删除peer: \(peerIDString.prefix(12))...")
        }
        // 保存到持久化存储
        Task {
            await savePeers()
        }
    }
    
    /// 清除所有 Peer
    public func clearAll() {
        peers.removeAll()
        deviceStatuses.removeAll()
        // 保存到持久化存储
        Task {
            await savePeers()
        }
    }
    
    /// 更新所有 Peer 的最后可见时间
    public func updateLastSeen(_ peerIDString: String) {
        guard var peer = peers[peerIDString] else {
            print("[PeerManager] ⚠️ 尝试更新不存在的 peer 的 lastSeenTime: \(peerIDString.prefix(12))...")
            return
        }
        let oldTime = peer.lastSeenTime
        peer.lastSeenTime = Date()
        peers[peerIDString] = peer
        let timeDiff = Date().timeIntervalSince(oldTime)
        if timeDiff > 5.0 {
            print("[PeerManager] ✅ 更新 lastSeenTime: \(peerIDString.prefix(12))... (距离上次: \(Int(timeDiff))秒)")
        }
        // 保存到持久化存储（带防抖）
        savePeersDebounced()
    }
    
    /// 立即保存所有 peer 到持久化存储（用于应用关闭时）
    public func saveAllPeers() async {
        await savePeers()
    }
}
