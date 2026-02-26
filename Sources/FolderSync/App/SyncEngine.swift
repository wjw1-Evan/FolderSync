import Foundation

/// 同步引擎
/// 负责核心的同步逻辑，包括对等点注册、同步协调和文件同步执行
@MainActor
class SyncEngine {
    weak var syncManager: SyncManager?
    weak var fileTransfer: FileTransfer?
    weak var folderStatistics: FolderStatistics?

    private let chunkSyncThreshold: Int64 = 256 * 1024  // 256KB，超过此大小的文件使用块级增量同步
    private let maxConcurrentTransfers = 8  // 最大并发传输数（上传/下载）

    init(syncManager: SyncManager, fileTransfer: FileTransfer, folderStatistics: FolderStatistics) {
        self.syncManager = syncManager
        self.fileTransfer = fileTransfer
        self.folderStatistics = folderStatistics
    }

    /// 与指定对等点同步指定文件夹
    /// 同步条件：1. 对方客户端在线（30秒内收到广播） 2. 同步ID相同
    /// - Parameter precomputedState: 可选预计算状态 (MST, metadata)；若提供则 performSync 跳过初始 calculateFullState
    func syncWithPeer(
        peer: PeerID, folder: SyncFolder,
        precomputedState: (MerkleSearchTree, [String: FileMetadata])? = nil
    ) {
        guard let syncManager = syncManager else { return }

        let peerID = peer.b58String
        let syncKey = "\(folder.syncID):\(peerID)"

        Task { @MainActor in
            // 标记为正在同步
            // 注意：SyncManager 可能已经在外部设置了此标记，但为了安全和统一，这里再次确认
            syncManager.syncInProgress.insert(syncKey)

            // 使用 defer 确保在函数返回时移除同步标记（无论是因为 guard 返回还是执行完成）
            defer {
                syncManager.syncInProgress.remove(syncKey)
            }

            // 条件1：检查设备是否在线（简化：仅使用广播判断）
            // 检查最近是否收到过广播（30秒内）
            guard let peerInfo = syncManager.peerManager.getPeer(peerID) else {
                AppLogger.syncPrint(
                    "[SyncEngine] ⏭️ [syncWithPeer] Peer不存在，跳过同步: \(peerID.prefix(12))... (syncID: \(folder.syncID))"
                )
                return
            }

            let timeSinceLastSeen = Date().timeIntervalSince(peerInfo.lastSeenTime)
            let isOnline = timeSinceLastSeen < 30.0  // 30秒内收到广播则认为在线

            if !isOnline {
                AppLogger.syncPrint(
                    "[SyncEngine] ⏭️ [syncWithPeer] 设备已离线（30秒内未收到广播），跳过同步: \(peerID.prefix(12))... (syncID: \(folder.syncID)), 距离上次广播=\(Int(timeSinceLastSeen))秒"
                )
                // 简化逻辑：无法访问的peer直接删除
                // 删除无法访问的 peer
                // 从所有syncID中移除该peer
                for folder in syncManager.folders {
                    syncManager.removeFolderPeer(folder.syncID, peerID: peerID)
                }
                // 从PeerManager中删除
                syncManager.peerManager.removePeer(peerID)
                return
            }

            // 检查远程设备是否有匹配的 syncID（从广播消息中获取）
            let remoteSyncIDs = Set(peerInfo.syncIDs)
            if !remoteSyncIDs.contains(folder.syncID) {
                AppLogger.syncPrint(
                    "[SyncEngine] ⏭️ [syncWithPeer] 远程设备没有匹配的 syncID，跳过同步: peer=\(peerID.prefix(12))..., 本地syncID=\(folder.syncID), 远程syncIDs=\(peerInfo.syncIDs)"
                )
                // 从该文件夹的 peer 列表中移除，避免重复尝试
                syncManager.removeFolderPeer(folder.syncID, peerID: peerID)
                return
            }

            // 注意：现在由 SyncManager 在启动 Task 前同步检查并插入 syncInProgress，
            // 以防止在高频广播下的任务风暴。这里不再进行重复的 contains 检查。

            // 确保对等点已注册（带重试机制）
            let registrationResult = await ensurePeerRegistered(peer: peer, peerID: peerID)

            guard registrationResult.success else {
                AppLogger.syncPrint(
                    "[SyncEngine] ❌ [syncWithPeer] 对等点注册失败，跳过同步: \(peerID.prefix(12))...")
                syncManager.updateFolderStatus(
                    folder.id, status: .error, message: "对等点注册失败", progress: 0.0,
                    errorDetail: "无法在 \(peerID) 上注册对等点，可能该设备已不再在线或网络受限。")
                return
            }

            await performSync(
                peer: peer, folder: folder, peerID: peerID, precomputedState: precomputedState)
        }
    }

    /// 确保对等点已注册（带重试机制）
    /// - Returns: (success: Bool, isNewlyRegistered: Bool) - 是否成功，是否新注册
    private func ensurePeerRegistered(peer: PeerID, peerID: String) async -> (
        success: Bool, isNewlyRegistered: Bool
    ) {
        guard let syncManager = syncManager else {
            return (false, false)
        }

        // 检查是否已注册
        if syncManager.p2pNode.registrationService.isRegistered(peerID) {
            return (true, false)
        }

        AppLogger.syncPrint(
            "[SyncEngine] ⚠️ [ensurePeerRegistered] 对等点未注册，尝试注册: \(peerID.prefix(12))...")

        // 获取对等点地址
        let peerAddresses = syncManager.p2pNode.peerManager.getAddresses(for: peerID)

        if peerAddresses.isEmpty {
            AppLogger.syncPrint(
                "[SyncEngine] ❌ [ensurePeerRegistered] 对等点无可用地址: \(peerID.prefix(12))...")
            return (false, false)
        }

        // 尝试注册
        let registered = syncManager.p2pNode.registrationService.registerPeer(
            peerID: peer, addresses: peerAddresses)

        if !registered {
            AppLogger.syncPrint(
                "[SyncEngine] ❌ [ensurePeerRegistered] 对等点注册失败: \(peerID.prefix(12))...")
            return (false, false)
        }

        AppLogger.syncPrint(
            "[SyncEngine] ✅ [ensurePeerRegistered] 对等点注册成功，等待注册完成: \(peerID.prefix(12))...")

        // 等待注册完成（使用重试机制，最多等待 2 秒）
        let maxWaitTime: TimeInterval = 2.0
        let checkInterval: TimeInterval = 0.2
        let maxRetries = Int(maxWaitTime / checkInterval)

        for attempt in 1...maxRetries {
            try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))

            if syncManager.p2pNode.registrationService.isRegistered(peerID) {
                AppLogger.syncPrint(
                    "[SyncEngine] ✅ [ensurePeerRegistered] 对等点注册确认成功: \(peerID.prefix(12))... (尝试 \(attempt)/\(maxRetries))"
                )
                return (true, true)
            }
        }

        // 即使等待超时，如果注册状态显示正在注册中，也认为成功（可能是异步延迟）
        let registrationState = syncManager.p2pNode.registrationService.getRegistrationState(peerID)
        if case .registering = registrationState {
            AppLogger.syncPrint(
                "[SyncEngine] ⚠️ [ensurePeerRegistered] 对等点正在注册中，继续尝试: \(peerID.prefix(12))...")
            return (true, true)
        }

        AppLogger.syncPrint(
            "[SyncEngine] ⚠️ [ensurePeerRegistered] 对等点注册等待超时，但继续尝试: \(peerID.prefix(12))...")
        return (true, true)  // 即使超时也继续，让同步过程处理
    }

    /// 执行同步操作
    /// - Parameter precomputedState: 可选预计算状态；若提供则跳过初始 calculateFullState，避免重复计算。
    private func performSync(
        peer: PeerID, folder: SyncFolder, peerID: String,
        precomputedState: (MerkleSearchTree, [String: FileMetadata])? = nil
    ) async {
        guard let syncManager = syncManager else { return }
        var session = SyncSession(folder: folder, peerID: peerID)

        AppLogger.syncPrint(
            "[SyncEngine] 🔄 开始同步: syncID=\(session.syncID), peer=\(peerID.prefix(12))...")

        do {
            // 阶段 1: 本地状态分析
            syncManager.updateFolderStatus(
                folder.id, status: .syncing, message: "正在分析本地变更...", progress: 0.1)
            await localStatePhase(session: &session, precomputed: precomputedState)

            // 阶段 2: 远程发现
            syncManager.updateFolderStatus(
                folder.id, status: .syncing, message: "正在获取远程状态...", progress: 0.2)
            try await discoveryPhase(session: &session)

            // 确认同步条件满足
            syncManager.addFolderPeer(session.syncID, peerID: peerID)
            syncManager.syncIDManager.updateLastSyncedAt(session.syncID)
            syncManager.peerManager.updateOnlineStatus(peerID, isOnline: true)
            syncManager.updateDeviceCounts()

            // 阶段 3: 计划
            syncManager.updateFolderStatus(
                folder.id, status: .syncing, message: "正在生成同步计划...", progress: 0.3)
            planningPhase(session: &session)

            // 快速路径：如果 MST 相同且无待执行操作，直接完成
            if session.actions.isEmpty && session.locallyDeleted.isEmpty
                && session.localMST?.rootHash == session.remoteHash
            {
                await finalizationPhase(session: session)
                return
            }

            // 阶段 4: 执行
            await executionPhase(session: &session)

            // 阶段 5: 完成
            await finalizationPhase(session: session)

            // 同步后冷却
            let cooldownKey = "\(peerID):\(session.syncID)"
            syncManager.peerSyncCooldown[cooldownKey] = Date()

        } catch {
            handleSyncError(error, session: session)
        }
    }

    /// 集中处理同步错误
    private func handleSyncError(_ error: Error, session: SyncSession) {
        guard let syncManager = syncManager else { return }
        let errorString = String(describing: error)

        // 区分“对等点离线”等常规网络错误和“真正”的错误
        let isUnreachable =
            (error as NSError).code == -3 || errorString.contains("DataChannel not ready")
            || (error as? SyncError) == .remoteFolderMissing

        if isUnreachable {
            AppLogger.syncPrint("[SyncEngine] ℹ️ 对等点暂时不可达或未配置，跳过: \(session.peerID.prefix(8))...")
            syncManager.removeFolderPeer(session.syncID, peerID: session.peerID)
            return
        }

        AppLogger.syncPrint("[SyncEngine] ❌ 同步失败: \(session.syncID) - \(errorString)")

        // 0. 重置待处理计数（错误兜底）
        syncManager.resetPendingTransfers(direction: .bidirectional)

        syncManager.updateFolderStatus(
            session.folderID,
            status: .error,
            message: "同步失败: \(error.localizedDescription)",
            progress: 0.0,
            errorDetail: errorString
        )

        let log = SyncLog(
            syncID: session.syncID,
            folderID: session.folderID,
            peerID: session.peerID,
            direction: .bidirectional,
            bytesTransferred: session.bytesTransferred,
            filesCount: session.filesSynced.count,
            startedAt: session.startedAt,
            completedAt: Date(),
            errorMessage: errorString
        )
        try? StorageManager.shared.addSyncLog(log)

        let cooldownKey = "\(session.peerID):\(session.syncID)"
        syncManager.peerSyncCooldown[cooldownKey] = Date()
    }

    /// 原子性地保存文件夹快照
    func saveSnapshotAtomically(
        syncID: String,
        folderID: UUID,
        metadata: [String: FileMetadata],
        folderCount: Int,
        totalSize: Int64
    ) async {
        guard self.syncManager != nil else { return }

        // 创建快照
        let snapshot = FolderSnapshot.fromFileMetadata(
            syncID: syncID,
            folderID: folderID,
            metadata: metadata
        )

        // 原子性地保存快照
        Task.detached {
            do {
                try StorageManager.shared.saveSnapshot(snapshot)
            } catch {
                AppLogger.syncPrint("[SyncEngine] ⚠️ 保存文件夹快照失败: \(error)")
            }
        }
    }
}
