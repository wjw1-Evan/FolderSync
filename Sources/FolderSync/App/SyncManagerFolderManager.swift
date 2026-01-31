import Foundation

/// 文件夹管理扩展
/// 负责文件夹的添加、删除、更新和监控
extension SyncManager {
    /// 刷新文件夹的文件数量和文件夹数量统计（不触发同步，立即执行）
    func refreshFileCount(for folder: SyncFolder) {
        folderStatistics.refreshFileCount(for: folder)
    }

    func addFolder(_ folder: SyncFolder) {
        // 验证文件夹权限
        let fileManager = FileManager.default
        // 统一使用解析符号链接后的路径，避免 /var 与 /private/var 等导致上传/读取时“文件不存在”
        let folderPath = folder.localPath.resolvingSymlinksInPath()
        var normalizedFolder = folder
        normalizedFolder.localPath = folderPath

        // 检查文件夹是否存在
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderPath.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            AppLogger.syncPrint("[SyncManager] ❌ 文件夹不存在或不是目录: \(folderPath.path)")
            updateFolderStatus(
                folder.id, status: .error, message: "文件夹不存在或不是目录",
                errorDetail: "路径: \(folderPath.path)\n请确保文件夹路径正确且未被移除。")
            return
        }

        // 检查读取权限
        guard fileManager.isReadableFile(atPath: folderPath.path) else {
            AppLogger.syncPrint("[SyncManager] ❌ 没有读取权限: \(folderPath.path)")
            updateFolderStatus(
                folder.id, status: .error, message: "没有读取权限，请检查文件夹权限设置",
                errorDetail: "路径: \(folderPath.path)\n请在系统设置中授予应用访问此文件夹的权限。")
            return
        }

        // 检查写入权限（双向同步和上传模式需要）
        if folder.mode == .twoWay || folder.mode == .uploadOnly {
            guard fileManager.isWritableFile(atPath: folderPath.path) else {
                AppLogger.syncPrint("[SyncManager] ❌ 没有写入权限: \(folderPath.path)")
                updateFolderStatus(
                    folder.id, status: .error, message: "没有写入权限，请检查文件夹权限设置",
                    errorDetail: "路径: \(folderPath.path)\n请在系统设置中授予应用访问此文件夹的权限。")
                return
            }
        }

        // 验证 syncID 格式
        guard SyncIDManager.isValidSyncID(folder.syncID) else {
            AppLogger.syncPrint("[SyncManager] ❌ syncID 格式无效: \(folder.syncID)")
            updateFolderStatus(
                folder.id, status: .error, message: "syncID 格式无效（至少4个字符，只能包含字母和数字）",
                errorDetail: "输入的 ID: \(folder.syncID)\n请使用符合要求的 Sync ID。")
            return
        }

        // 注册 syncID
        if !syncIDManager.registerSyncID(folder.syncID, folderID: folder.id) {
            AppLogger.syncPrint("[SyncManager] ⚠️ syncID 已存在或文件夹已关联其他 syncID: \(folder.syncID)")
            // 如果 syncID 已存在，检查是否是同一个文件夹
            if let existingInfo = syncIDManager.getSyncIDInfo(folder.syncID),
                existingInfo.folderID != folder.id
            {
                updateFolderStatus(
                    folder.id, status: .error, message: "syncID 已被其他文件夹使用",
                    errorDetail: "该 Sync ID 已被本地其他同步文件夹占用，请更换 ID 或移除冲突文件夹。")
                return
            }
        }

        folders.append(normalizedFolder)
        do {
            try StorageManager.shared.saveFolder(normalizedFolder)
            AppLogger.syncPrint(
                "[SyncManager] ✅ 文件夹配置已保存: \(normalizedFolder.localPath.path) (syncID: \(folder.syncID))"
            )
        } catch {
            AppLogger.syncPrint("[SyncManager] ❌ 无法保存文件夹配置: \(error)")
            AppLogger.syncPrint("[SyncManager] 错误详情: \(error.localizedDescription)")
            // 即使保存失败，也从内存中移除，避免不一致
            folders.removeAll { $0.id == folder.id }
            syncIDManager.unregisterSyncID(folder.syncID)
            updateFolderStatus(
                folder.id, status: .error, message: "无法保存配置: \(error.localizedDescription)",
                errorDetail: String(describing: error))
            return
        }

        // 重要：检查本地文件夹是否为空，如果为空则清空快照数据
        // 这样可以避免添加新文件夹时，如果之前有快照数据（可能是其他文件夹的），误判为删除
        Task {
            let fileManager = FileManager.default
            let folderPath = normalizedFolder.localPath.path

            // 检查文件夹是否为空（只检查文件，不包括子目录）
            let contents = try? fileManager.contentsOfDirectory(atPath: folderPath)
            let isEmpty = contents?.isEmpty ?? true

            if isEmpty {
                // 文件夹为空，清空该 syncID 的快照数据和状态
                AppLogger.syncPrint("[SyncManager] 🔄 检测到新文件夹为空，清空快照数据: syncID=\(folder.syncID)")
                await MainActor.run {
                    // 清空 lastKnownLocalPaths 和 lastKnownMetadata
                    self.lastKnownLocalPaths[folder.syncID] = []
                    self.lastKnownMetadata[folder.syncID] = [:]

                    // 清空删除记录
                    self.removeDeletedPaths(for: folder.syncID)

                    // 清空文件状态存储
                    self.fileStateStores.removeValue(forKey: folder.syncID)

                    // 删除快照文件（如果存在）
                    try? StorageManager.shared.deleteSnapshot(syncID: folder.syncID)

                    AppLogger.syncPrint("[SyncManager] ✅ 已清空新文件夹的快照数据: syncID=\(folder.syncID)")
                }
            } else {
                // 文件夹不为空，检查是否有旧的快照数据
                // 如果快照数据中的文件路径在当前文件夹中不存在，可能是旧的快照数据，应该清空
                await MainActor.run {
                    if let lastKnown = self.lastKnownLocalPaths[folder.syncID],
                        !lastKnown.isEmpty
                    {
                        // 检查快照中的文件是否在当前文件夹中存在
                        var hasValidFiles = false
                        for path in lastKnown {
                            let fileURL = normalizedFolder.localPath.appendingPathComponent(path)
                            if fileManager.fileExists(atPath: fileURL.path) {
                                hasValidFiles = true
                                break
                            }
                        }

                        // 如果快照中的文件都不存在，清空快照数据
                        if !hasValidFiles {
                            AppLogger.syncPrint(
                                "[SyncManager] 🔄 检测到快照数据中的文件都不存在，清空快照数据: syncID=\(folder.syncID)")
                            self.lastKnownLocalPaths[folder.syncID] = []
                            self.lastKnownMetadata[folder.syncID] = [:]
                            self.removeDeletedPaths(for: folder.syncID)
                            self.fileStateStores.removeValue(forKey: folder.syncID)
                            try? StorageManager.shared.deleteSnapshot(syncID: folder.syncID)
                            AppLogger.syncPrint(
                                "[SyncManager] ✅ 已清空无效的快照数据: syncID=\(folder.syncID)")
                        }
                    }
                }
            }
        }

        startMonitoring(folder)

        // 立即统计文件数量和文件夹数量
        AppLogger.syncPrint("[SyncManager] 📊 开始统计文件夹内容: \(folder.localPath.path)")
        refreshFileCount(for: folder)

        // 更新广播中的 syncID 列表
        updateBroadcastSyncIDs()

        AppLogger.syncPrint("[SyncManager] ℹ️ 新文件夹已添加，准备开始同步...")

        Task {
            // 延迟 3.5 秒后开始同步，确保：
            // P2PNode 已经等待了 2 秒，这里再等待 1.5 秒，总共约 3.5 秒
            // 1. 服务已发布
            // 2. 如果有现有 peer，可以立即同步
            // 3. 如果没有 peer，会等待 peer 发现后自动同步（通过 onPeerDiscovered 回调）
            try? await Task.sleep(nanoseconds: 2_500_000_000)  // 等待 2.5 秒

            // 自动开始同步
            self.triggerSync(for: folder)
        }
    }

    func removeFolder(_ folder: SyncFolder) {
        stopMonitoring(folder)
        folders.removeAll { $0.id == folder.id }
        syncIDManager.unregisterSyncIDByFolderID(folder.id)
        removeDeletedPaths(for: folder.syncID)
        // 防抖任务由 FolderMonitor 管理，停止监控时会自动取消
        try? StorageManager.shared.deleteFolder(folder.id)
        // 更新广播中的 syncID 列表
        updateBroadcastSyncIDs()
    }

    func updateFolder(_ folder: SyncFolder) {
        guard let idx = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        // 重要：保留现有的统计值，避免覆盖为 nil
        var updatedFolder = folder
        let existingFolder = folders[idx]
        // 如果新 folder 的统计值为 nil，保留旧值
        if updatedFolder.fileCount == nil {
            updatedFolder.fileCount = existingFolder.fileCount
        }
        if updatedFolder.folderCount == nil {
            updatedFolder.folderCount = existingFolder.folderCount
        }
        if updatedFolder.totalSize == nil {
            updatedFolder.totalSize = existingFolder.totalSize
        }
        folders[idx] = updatedFolder
        try? StorageManager.shared.saveFolder(updatedFolder)
    }

    func startMonitoring(_ folder: SyncFolder) {
        folderMonitor.startMonitoring(folder)
    }

    func stopMonitoring(_ folder: SyncFolder) {
        folderMonitor.stopMonitoring(folder)
    }

    @MainActor
    func addFolderPeer(_ syncID: String, peerID: String) {
        syncIDManager.addPeer(peerID, to: syncID)
        updatePeerCount(for: syncID)
    }

    @MainActor
    func removeFolderPeer(_ syncID: String, peerID: String) {
        syncIDManager.removePeer(peerID, from: syncID)
        updatePeerCount(for: syncID)
        // 从 syncID 移除 peer
    }

    @MainActor
    func updatePeerCount(for syncID: String) {
        if let index = folders.firstIndex(where: { $0.syncID == syncID }) {
            // 获取该 syncID 的所有 peer，但只统计在线的
            let peerIDs = syncIDManager.getPeers(for: syncID)
            let onlinePeerCount = peerIDs.filter { peerID in
                peerManager.isOnline(peerID)
            }.count

            // 创建新的文件夹对象以触发 @Published 更新
            var updatedFolder = folders[index]
            updatedFolder.peerCount = onlinePeerCount
            folders[index] = updatedFolder
            // 持久化保存更新
            do {
                try StorageManager.shared.saveFolder(updatedFolder)
            } catch {
                AppLogger.syncPrint("[SyncManager] ⚠️ 无法保存文件夹 peerCount 更新: \(error)")
            }
        }
    }

    func updateFolderStatus(
        _ id: UUID, status: SyncStatus, message: String? = nil, progress: Double = 0.0,
        errorDetail: String? = nil
    ) {
        if let index = folders.firstIndex(where: { $0.id == id }) {
            // 创建新的文件夹对象以触发 @Published 更新
            var updatedFolder = folders[index]
            updatedFolder.status = status
            updatedFolder.lastSyncMessage = message
            updatedFolder.syncProgress = progress

            if let detail = errorDetail {
                updatedFolder.lastErrorDetail = detail
            }

            if status == .synced {
                updatedFolder.lastSyncedAt = Date()
                // 同步成功时清理旧的错误详情
                updatedFolder.lastErrorDetail = nil
            }
            folders[index] = updatedFolder

            // 持久化保存状态更新，确保重启后能恢复
            // 注意：保存时使用最新的 folder 对象，确保包含所有最新值（包括统计值）
            do {
                // 再次获取最新的 folder 对象，确保保存的是最新状态（包括统计值）
                if let latestFolder = folders.first(where: { $0.id == id }) {
                    try StorageManager.shared.saveFolder(latestFolder)
                } else {
                    // 如果找不到，使用 updatedFolder（虽然不太可能发生）
                    try StorageManager.shared.saveFolder(updatedFolder)
                }
            } catch {
                AppLogger.syncPrint("[SyncManager] ⚠️ 无法保存文件夹状态更新: \(error)")
                AppLogger.syncPrint("[SyncManager] 错误详情: \(error.localizedDescription)")
            }
        }
    }

    /// 更新文件夹错误状态
    func updateFolderError(_ id: UUID, message: String, detail: String? = nil) {
        updateFolderStatus(id, status: .error, message: message, errorDetail: detail)
    }

    func addPendingTransfers(_ count: Int) {
        guard count > 0 else { return }
        pendingTransferFileCount += count
    }

    func completePendingTransfers(_ count: Int = 1) {
        guard count > 0 else { return }
        pendingTransferFileCount = max(0, pendingTransferFileCount - count)
    }
}
