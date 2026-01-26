import Foundation

/// SyncID 信息类（使用 class 以支持并发修改）
public class SyncIDInfo {
    public let syncID: String
    public let folderID: UUID
    public let createdAt: Date
    public var peerIDs: Set<String>
    public var lastSyncedAt: Date?
    
    public init(syncID: String, folderID: UUID, createdAt: Date = Date(), peerIDs: Set<String> = [], lastSyncedAt: Date? = nil) {
        self.syncID = syncID
        self.folderID = folderID
        self.createdAt = createdAt
        self.peerIDs = peerIDs
        self.lastSyncedAt = lastSyncedAt
    }
}

/// 统一的 SyncID 管理器
@MainActor
public class SyncIDManager: ObservableObject {
    // syncID -> SyncIDInfo
    private var syncIDMap: [String: SyncIDInfo] = [:]
    
    // folderID -> syncID
    private var folderToSyncID: [UUID: String] = [:]
    
    private let queue = DispatchQueue(label: "com.foldersync.syncidmanager", attributes: .concurrent)
    
    public init() {}
    
    // MARK: - SyncID 生成
    
    /// 生成随机 syncID
    /// - Parameter length: syncID 长度，默认 8
    /// - Returns: 生成的 syncID
    public static func generateSyncID(length: Int = 8) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in letters.randomElement()! })
    }
    
    /// 验证 syncID 格式
    /// - Parameter syncID: 要验证的 syncID
    /// - Returns: 是否有效
    public static func isValidSyncID(_ syncID: String) -> Bool {
        guard syncID.count >= 4 else { return false }
        let allowedChars = CharacterSet.alphanumerics
        return syncID.unicodeScalars.allSatisfy { allowedChars.contains($0) }
    }
    
    // MARK: - SyncID 注册和管理
    
    /// 注册 syncID
    /// - Parameters:
    ///   - syncID: syncID
    ///   - folderID: 关联的文件夹 ID
    /// - Returns: 是否成功注册（如果已存在则返回 false）
    public func registerSyncID(_ syncID: String, folderID: UUID) -> Bool {
        return queue.sync(flags: .barrier) {
            // 检查 syncID 是否已存在
            if syncIDMap[syncID] != nil {
                return false
            }
            
            // 检查 folderID 是否已关联其他 syncID
            if folderToSyncID[folderID] != nil {
                return false
            }
            
            let info = SyncIDInfo(syncID: syncID, folderID: folderID)
            syncIDMap[syncID] = info
            folderToSyncID[folderID] = syncID
            return true
        }
    }
    
    /// 移除 syncID
    /// - Parameter syncID: 要移除的 syncID
    public func unregisterSyncID(_ syncID: String) {
        Task { @MainActor in
            if let info = self.syncIDMap[syncID] {
                self.folderToSyncID.removeValue(forKey: info.folderID)
                self.syncIDMap.removeValue(forKey: syncID)
            }
        }
    }
    
    /// 通过 folderID 移除 syncID
    /// - Parameter folderID: 文件夹 ID
    public func unregisterSyncIDByFolderID(_ folderID: UUID) {
        Task { @MainActor in
            if let syncID = self.folderToSyncID[folderID] {
                self.syncIDMap.removeValue(forKey: syncID)
                self.folderToSyncID.removeValue(forKey: folderID)
            }
        }
    }
    
    // MARK: - 查询
    
    /// 获取 syncID 信息
    /// - Parameter syncID: syncID
    /// - Returns: SyncIDInfo，如果不存在返回 nil
    public func getSyncIDInfo(_ syncID: String) -> SyncIDInfo? {
        return queue.sync {
            return syncIDMap[syncID]
        }
    }
    
    /// 通过 folderID 获取 syncID
    /// - Parameter folderID: 文件夹 ID
    /// - Returns: syncID，如果不存在返回 nil
    public func getSyncID(for folderID: UUID) -> String? {
        return queue.sync {
            return folderToSyncID[folderID]
        }
    }
    
    /// 检查 syncID 是否存在（本地）
    /// - Parameter syncID: syncID
    /// - Returns: 是否存在
    public func hasSyncID(_ syncID: String) -> Bool {
        return queue.sync {
            return syncIDMap[syncID] != nil
        }
    }
    
    /// 获取所有 syncID
    /// - Returns: 所有 syncID 列表
    public func getAllSyncIDs() -> [String] {
        return queue.sync {
            return Array(syncIDMap.keys)
        }
    }
    
    /// 获取所有 SyncIDInfo
    /// - Returns: 所有 SyncIDInfo 列表
    public var allSyncIDInfos: [SyncIDInfo] {
        return queue.sync {
            return Array(syncIDMap.values)
        }
    }
    
    // MARK: - Peer 关联管理
    
    /// 添加 peer 到 syncID
    /// - Parameters:
    ///   - syncID: syncID
    ///   - peerID: peer ID
    public func addPeer(_ peerID: String, to syncID: String) {
        Task { @MainActor in
            if let info = self.syncIDMap[syncID] {
                info.peerIDs.insert(peerID)
            }
        }
    }
    
    /// 从 syncID 移除 peer
    /// - Parameters:
    ///   - syncID: syncID
    ///   - peerID: peer ID
    public func removePeer(_ peerID: String, from syncID: String) {
        Task { @MainActor in
            if let info = self.syncIDMap[syncID] {
                info.peerIDs.remove(peerID)
            }
        }
    }
    
    /// 获取 syncID 的所有 peer
    /// - Parameter syncID: syncID
    /// - Returns: peer ID 集合
    public func getPeers(for syncID: String) -> Set<String> {
        return queue.sync {
            return syncIDMap[syncID]?.peerIDs ?? []
        }
    }
    
    /// 获取 syncID 的 peer 数量
    /// - Parameter syncID: syncID
    /// - Returns: peer 数量
    public func getPeerCount(for syncID: String) -> Int {
        return queue.sync {
            return syncIDMap[syncID]?.peerIDs.count ?? 0
        }
    }
    
    // MARK: - 统计
    
    /// 获取 syncID 总数
    public var totalSyncIDCount: Int {
        return queue.sync {
            return syncIDMap.count
        }
    }
    
    /// 更新最后同步时间
    /// - Parameters:
    ///   - syncID: syncID
    ///   - date: 同步时间
    public func updateLastSyncedAt(_ syncID: String, date: Date = Date()) {
        Task { @MainActor in
            if let info = self.syncIDMap[syncID] {
                info.lastSyncedAt = date
            }
        }
    }
}
