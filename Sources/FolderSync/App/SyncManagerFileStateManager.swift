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
    ///   - vectorClock: 可选的外部 Vector Clock（通常来自对等点）
    func deleteFileAtomically(
        path: String, syncID: String, peerID: String, vectorClock: VectorClock? = nil
    ) {
        guard let folder = folders.first(where: { $0.syncID == syncID }) else { return }
        let folderID = folder.id

        // 1. 获取当前 Vector Clock
        let currentVC =
            VectorClockManager.getVectorClock(folderID: folderID, syncID: syncID, path: path)
            ?? VectorClock()

        // 2. 更新 Vector Clock
        var updatedVC: VectorClock
        if let externalVC = vectorClock {
            // 如果提供了外部 VC（例如来自远端删除请求），则进行合并
            updatedVC = VectorClockManager.mergeVectorClocks(
                localVC: currentVC, remoteVC: externalVC)
        } else {
            // 如果是本地发起删除，则递增本地 PeerID
            updatedVC = currentVC
            updatedVC.increment(for: peerID)
        }

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

        // 5.1 清理空父目录（避免重命名后旧目录残留）
        removeEmptyParentDirectories(root: folder.localPath, relativePath: path)

        // 6. 保存 Vector Clock（标记为删除状态）
        VectorClockManager.saveVectorClock(
            folderID: folderID, syncID: syncID, path: path, vc: updatedVC)

        // 7. 更新旧的删除记录（兼容性）
        var dp = deletedPaths(for: syncID)
        dp.insert(path)
        updateDeletedPaths(dp, for: syncID)

        AppLogger.syncPrint("[SyncManager] ✅ 原子性删除文件: \(path) (syncID: \(syncID))")
    }

    /// 删除空父目录（从文件所在目录向上递归，直到遇到非空或到达根目录）
    private func removeEmptyParentDirectories(root: URL, relativePath: String) {
        let parentPath = (relativePath as NSString).deletingLastPathComponent
        guard !parentPath.isEmpty else { return }

        let fileManager = FileManager.default
        var currentURL = root.appendingPathComponent(parentPath)

        while currentURL.path.hasPrefix(root.path), currentURL.path != root.path {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: currentURL.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                break
            }

            if let contents = try? fileManager.contentsOfDirectory(atPath: currentURL.path),
                contents.isEmpty
            {
                try? fileManager.removeItem(at: currentURL)
                currentURL.deleteLastPathComponent()
                continue
            }
            break
        }
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
            AppLogger.syncPrint("[SyncManager] ⚠️ 无法保存删除记录: \(error.localizedDescription)")
        }
    }
}
