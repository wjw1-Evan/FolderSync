import Foundation

/// 文件状态和删除记录管理扩展
extension SyncManager {
    /// 获取文件状态存储（为每个 syncID 创建独立的存储）
    func getFileStateStore(for syncID: String) -> FileStateStore {
        if let store = fileStateStores[syncID] {
            return store
        }
        let store = FileStateStore()
        fileStateStores[syncID] = store
        return store
    }
    
    /// 原子性删除文件
    /// - Parameters:
    ///   - path: 文件相对路径
    ///   - syncID: 同步 ID
    ///   - peerID: 当前设备的 PeerID
    func deleteFileAtomically(path: String, syncID: String, peerID: String) {
        guard let folder = folders.first(where: { $0.syncID == syncID }) else { return }
        let folderID = folder.id

        // 1. 获取当前 Vector Clock
        let currentVC =
            VectorClockManager.getVectorClock(folderID: folderID, syncID: syncID, path: path)
            ?? VectorClock()
        
        // 2. 递增 Vector Clock（标记删除操作）
        var updatedVC = currentVC
        updatedVC.increment(for: peerID)
        
        // 3. 创建删除记录
        let deletionRecord = DeletionRecord(
            deletedAt: Date(),
            deletedBy: peerID,
            vectorClock: updatedVC
        )
        
        // 4. 原子性更新状态
        let stateStore = getFileStateStore(for: syncID)
        stateStore.setDeleted(path: path, record: deletionRecord)
        
        // 5. 删除文件（如果存在）
        let fileURL = folder.localPath.appendingPathComponent(path)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: fileURL)
        }
        
        // 6. 保存 Vector Clock（标记为删除状态）
        VectorClockManager.saveVectorClock(folderID: folderID, syncID: syncID, path: path, vc: updatedVC)
        
        // 7. 更新旧的删除记录（兼容性）
        var dp = deletedPaths(for: syncID)
        dp.insert(path)
        updateDeletedPaths(dp, for: syncID)
        
        print("[SyncManager] ✅ 原子性删除文件: \(path) (syncID: \(syncID))")
    }
    
    func deletedPaths(for syncID: String) -> Set<String> {
        // 优先从新的状态存储获取
        let stateStore = getFileStateStore(for: syncID)
        let deletedPaths = stateStore.getDeletedPaths()
        if !deletedPaths.isEmpty {
            return deletedPaths
        }
        // 兼容旧格式
        return deletedRecords[syncID] ?? []
    }

    func updateDeletedPaths(_ paths: Set<String>, for syncID: String) {
        // 更新旧格式（兼容性）
        if paths.isEmpty {
            deletedRecords.removeValue(forKey: syncID)
        } else {
            deletedRecords[syncID] = paths
        }
        persistDeletedRecords()
    }

    func removeDeletedPaths(for syncID: String) {
        deletedRecords.removeValue(forKey: syncID)
        persistDeletedRecords()
        // 清理状态存储中的过期删除记录
        let stateStore = getFileStateStore(for: syncID)
        stateStore.cleanupExpiredDeletions { path in
            // 检查是否所有在线对等点都已确认删除
            // 这里简化处理：如果文件不在任何对等点的文件列表中，认为已确认
            return true  // TODO: 实现真正的多客户端确认机制
        }
    }

    func persistDeletedRecords() {
        do {
            try StorageManager.shared.saveDeletedRecords(deletedRecords)
        } catch {
            print("[SyncManager] ⚠️ 无法保存删除记录: \(error.localizedDescription)")
        }
    }
}
