import Foundation

/// 同步引擎
/// 负责核心的同步逻辑，包括对等点注册、同步协调和文件同步执行
@MainActor
class SyncEngine {
    weak var syncManager: SyncManager?
    weak var fileTransfer: FileTransfer?
    weak var folderStatistics: FolderStatistics?

    private let chunkSyncThreshold: Int64 = 1 * 1024 * 1024  // 1MB，超过此大小的文件使用块级增量同步
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

            // 检查是否正在同步
            if syncManager.syncInProgress.contains(syncKey) {
                return
            }

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

            // 标记为正在同步
            syncManager.syncInProgress.insert(syncKey)

            // 使用 defer 确保在函数返回时移除同步标记
            defer {
                syncManager.syncInProgress.remove(syncKey)
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
        guard let syncManager = syncManager,
            let folderStatistics = folderStatistics
        else {
            AppLogger.syncPrint("[SyncEngine] ❌ performSync: syncManager 或 folderStatistics 为空")
            return
        }

        // fileTransfer 在异步任务中使用，只需要检查是否存在
        guard fileTransfer != nil else {
            AppLogger.syncPrint("[SyncEngine] ❌ performSync: fileTransfer 为空")
            return
        }

        let startedAt = Date()
        let folderID = folder.id
        let syncID = folder.syncID

        AppLogger.syncPrint("[SyncEngine] 🔄 开始同步: syncID=\(syncID), peer=\(peerID.prefix(12))...")

        // 重要：从 syncManager 中获取最新的 folder 对象，避免使用过时的统计值
        let currentFolder = await MainActor.run {
            return syncManager.folders.first(where: { $0.id == folderID })
        }

        guard let currentFolder = currentFolder else {
            AppLogger.syncPrint("[SyncEngine] ⚠️ performSync: 文件夹已不存在: \(folderID)")
            // 文件夹不存在，无法记录日志
            return
        }

        do {
            guard !peerID.isEmpty else {
                AppLogger.syncPrint("[SyncEngine] ❌ performSync: PeerID 无效")
                syncManager.updateFolderStatus(
                    currentFolder.id, status: .error, message: "PeerID 无效",
                    errorDetail: "同步尝试中使用的 PeerID 为空。")
                // 记录错误日志
                let log = SyncLog(
                    syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional,
                    bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(),
                    errorMessage: "PeerID 无效")
                try? StorageManager.shared.addSyncLog(log)
                return
            }

            syncManager.updateFolderStatus(
                currentFolder.id, status: .syncing, message: "正在连接到 \(peerID.prefix(12))...",
                progress: 0.0)

            // 获取远程 MST 根
            let peerAddresses = syncManager.p2pNode.peerManager.getAddresses(for: peer.b58String)
            if peerAddresses.isEmpty {
                AppLogger.syncPrint("[SyncEngine] ⚠️ performSync: 对等点没有可用地址")
                syncManager.updateFolderStatus(
                    currentFolder.id, status: .error, message: "对等点无可用地址", progress: 0.0,
                    errorDetail: "无法通过局域网发现该对等点的 IP 地址和信令端口。")
                // 记录错误日志
                let log = SyncLog(
                    syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional,
                    bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(),
                    errorMessage: "对等点无可用地址")
                try? StorageManager.shared.addSyncLog(log)
                return
            }

            // 尝试使用 WebRTC 服务 (带重试机制)
            var rootRes: SyncResponse?
            var lastError: Error?
            let maxRetries = 3

            for attempt in 1...maxRetries {
                do {
                    rootRes = try await syncManager.p2pNode.sendRequest(
                        .getMST(syncID: syncID),
                        to: peerID
                    )
                    lastError = nil
                    break  // 成功，退出重试
                } catch {
                    lastError = error
                    let errorString = String(describing: error)
                    AppLogger.syncPrint(
                        "[SyncEngine] ⚠️ [performSync] 获取 MST 根尝试 \(attempt)/\(maxRetries) 失败: \(errorString)"
                    )

                    if attempt < maxRetries {
                        // 延迟 1-2 秒后重试
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                    }
                }
            }

            if let error = lastError {
                let errorString = String(describing: error)
                AppLogger.syncPrint("[SyncEngine] ❌ [performSync] WebRTC 请求最终失败: \(errorString)")

                syncManager.updateFolderStatus(
                    currentFolder.id, status: .error,
                    message: "对等点连接失败 (多次重试后): \(error.localizedDescription)", progress: 0.0,
                    errorDetail: String(describing: error))
                // 记录错误日志
                let log = SyncLog(
                    syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional,
                    bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(),
                    errorMessage: "对等点连接失败: \(error.localizedDescription)")
                try? StorageManager.shared.addSyncLog(log)
                return
            }

            // 条件2：验证同步ID是否匹配（通过检查远程是否有该syncID）
            guard let rootRes = rootRes else {
                AppLogger.syncPrint("[SyncEngine] ❌ performSync: rootRes 为 nil")
                return
            }

            if case .error = rootRes {
                // 远程没有这个syncID，说明该设备不需要同步此文件夹
                // 这是正常情况：不同设备可能有不同的文件夹配置
                // 远程设备没有该 syncID（正常情况）
                syncManager.removeFolderPeer(syncID, peerID: peerID)
                return
            }

            // 同步条件满足：1. 对方在线 ✓ 2. 同步ID匹配 ✓
            // Peer confirmed to have this folder (syncID matches)
            // 同步条件满足：对方在线且 syncID 匹配
            syncManager.addFolderPeer(syncID, peerID: peerID)
            syncManager.syncIDManager.updateLastSyncedAt(syncID)
            syncManager.peerManager.updateOnlineStatus(peerID, isOnline: true)
            syncManager.updateDeviceCounts()

            guard case .mstRoot(_, let remoteHash) = rootRes else {
                AppLogger.syncPrint("[SyncEngine] ❌ performSync: rootRes 不是 mstRoot 类型")
                // 记录错误日志
                let log = SyncLog(
                    syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional,
                    bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(),
                    errorMessage: "获取远程 MST 根失败：响应类型错误")
                try? StorageManager.shared.addSyncLog(log)
                return
            }

            let (localMST, localMetadata): (MerkleSearchTree, [String: FileMetadata])
            if let pre = precomputedState {
                localMST = pre.0
                localMetadata = ConflictFileFilter.filterConflictFiles(pre.1)
            } else {
                let (mst, raw, _, _) = await folderStatistics.calculateFullState(for: currentFolder)
                localMST = mst
                localMetadata = ConflictFileFilter.filterConflictFiles(raw)
            }

            let currentPaths = Set(localMetadata.keys)
            let lastKnown = syncManager.lastKnownLocalPaths[syncID] ?? []
            let lastKnownMeta = syncManager.lastKnownMetadata[syncID] ?? [:]

            // 如果是第一次同步（lastKnown 为空），初始化 lastKnown 为当前路径，不检测删除
            // 这样可以避免第一次同步时误判删除
            // 重要：如果本地文件夹为空，即使有快照数据，也应该视为第一次同步
            // 因为空文件夹不应该删除远程文件
            let isFirstSync = lastKnown.isEmpty

            // 检测文件重命名：通过比较哈希值匹配删除的文件和新文件
            var renamedFiles: [String: String] = [:]  // oldPath -> newPath
            var locallyDeleted: Set<String> = []
            let fileManager = FileManager.default

            // 第一步：找出所有"消失"的文件（可能在 lastKnown 中但不在 currentPaths 中）
            // 注意：第一次同步时跳过删除检测
            var disappearedFiles: [String: FileMetadata] = [:]  // path -> metadata (from last sync)
            if !isFirstSync {
                for path in lastKnown {
                    if !currentPaths.contains(path) {
                        let fileURL = currentFolder.localPath.appendingPathComponent(path)
                        if !fileManager.fileExists(atPath: fileURL.path) {
                            // 文件确实不存在，可能是删除或重命名
                            // 从上次同步的元数据中获取哈希值
                            if let oldMeta = lastKnownMeta[path] {
                                disappearedFiles[path] = oldMeta
                            } else {
                                // 无法获取旧元数据，先标记为删除
                                locallyDeleted.insert(path)
                            }
                        }
                    }
                }
            }

            // 第二步：找出所有新文件（在 currentPaths 中但不在 lastKnown 中）
            // 注意：第一次同步时，所有文件都是"新文件"，这是正常的
            var newFiles: [String: FileMetadata] = [:]
            if !isFirstSync {
                for path in currentPaths {
                    if !lastKnown.contains(path) {
                        if let meta = localMetadata[path] {
                            newFiles[path] = meta
                        }
                    }
                }
            }

            // 第三步：通过哈希值匹配重命名（第一次同步时跳过）
            for (oldPath, oldMeta) in disappearedFiles {
                // 查找具有相同哈希值的新文件
                if let (newPath, _) = newFiles.first(where: { $0.value.hash == oldMeta.hash }) {
                    // 找到匹配！这是重命名操作
                    renamedFiles[oldPath] = newPath
                    newFiles.removeValue(forKey: newPath)  // 从新文件列表中移除，因为它是重命名
                    locallyDeleted.insert(oldPath)  // 仍然标记为已删除，以便创建删除记录
                    AppLogger.syncPrint("[SyncEngine] 🔄 检测到文件重命名: \(oldPath) -> \(newPath)")
                } else {
                    // 没有找到匹配，这是真正的删除
                    locallyDeleted.insert(oldPath)
                }
            }

            // 处理重命名：迁移 Vector Clock 路径映射（使用 VectorClockManager）
            for (oldPath, newPath) in renamedFiles {
                VectorClockManager.migrateVectorClock(
                    folderID: folderID,
                    syncID: syncID,
                    oldPath: oldPath,
                    newPath: newPath
                )
            }

            // 更新 deletedPaths（只包含真正的删除，不包括重命名）
            // 使用原子性删除操作创建删除记录
            if !locallyDeleted.isEmpty {
                let myPeerID = await MainActor.run { syncManager.p2pNode.peerID?.b58String ?? "" }

                for path in locallyDeleted {
                    // 使用原子性删除操作创建删除记录
                    await MainActor.run {
                        syncManager.deleteFileAtomically(
                            path: path, syncID: syncID, peerID: myPeerID)
                    }
                }

                // 更新旧的删除记录格式（兼容性）
                var dp = syncManager.deletedPaths(for: syncID)
                dp.formUnion(locallyDeleted)
                syncManager.updateDeletedPaths(dp, for: syncID)
            }

            let mode = currentFolder.mode

            if localMST.rootHash == remoteHash && locallyDeleted.isEmpty {
                // 本地和远程已经同步
                // 本地和远程已同步
                syncManager.lastKnownLocalPaths[syncID] = currentPaths
                syncManager.lastKnownMetadata[syncID] = localMetadata  // 保存当前元数据用于下次重命名检测

                // 原子性地保存文件夹快照（即使没有文件操作）
                await saveSnapshotAtomically(
                    syncID: syncID,
                    folderID: folderID,
                    metadata: localMetadata,
                    folderCount: 0,  // 这里不需要重新计算，使用占位值
                    totalSize: 0
                )
                syncManager.updateFolderStatus(
                    currentFolder.id, status: .synced, message: "Up to date", progress: 1.0)
                syncManager.syncIDManager.updateLastSyncedAt(syncID)
                syncManager.peerManager.updateOnlineStatus(peerID, isOnline: true)
                syncManager.updateDeviceCounts()
                // 记录成功日志（即使没有文件操作）
                let direction: SyncLog.Direction =
                    mode == .uploadOnly
                    ? .upload : (mode == .downloadOnly ? .download : .bidirectional)
                let log = SyncLog(
                    syncID: syncID, folderID: folderID, peerID: peerID, direction: direction,
                    bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(),
                    syncedFiles: nil)
                try? StorageManager.shared.addSyncLog(log)
                return
            }

            // 2. Roots differ, get remote file list (带重试逻辑)
            syncManager.updateFolderStatus(
                currentFolder.id, status: .syncing, message: "正在获取远程文件列表...", progress: 0.1)

            var filesRes: SyncResponse?
            var filesError: Error?

            for attempt in 1...maxRetries {
                do {
                    filesRes = try await syncManager.p2pNode.sendRequest(
                        .getFiles(syncID: syncID),
                        to: peerID
                    )
                    filesError = nil
                    break
                } catch {
                    filesError = error
                    AppLogger.syncPrint(
                        "[SyncEngine] ⚠️ [performSync] 获取远程文件列表尝试 \(attempt)/\(maxRetries) 失败: \(error)"
                    )
                    if attempt < maxRetries {
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)  // 重试间隔稍长一些
                    }
                }
            }

            guard let finalFilesRes = filesRes else {
                let error =
                    filesError
                    ?? NSError(
                        domain: "SyncEngine", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Unknown error"])
                AppLogger.syncPrint("[SyncEngine] ❌ [performSync] 获取远程文件列表最终失败: \(error)")
                syncManager.updateFolderStatus(
                    currentFolder.id, status: .error,
                    message: "获取远程文件列表失败 (多次重试后): \(error.localizedDescription)",
                    errorDetail: String(describing: error))
                // 记录错误日志
                let log = SyncLog(
                    syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional,
                    bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(),
                    errorMessage: "获取远程文件列表失败: \(error.localizedDescription)")
                try? StorageManager.shared.addSyncLog(log)
                return
            }

            let filesResValue = finalFilesRes  // 重命名以便后续使用逻辑匹配

            // 处理新的统一状态格式（filesV2）或旧格式（files）
            var remoteEntries: [String: FileMetadata] = [:]
            var remoteDeletedPaths: [String] = []
            var remoteStates: [String: FileState] = [:]

            switch filesResValue {
            case .filesV2(_, let states):
                // 新格式：统一状态表示
                remoteStates = states
                // 提取文件元数据和删除记录
                for (path, state) in states {
                    switch state {
                    case .exists(let meta):
                        // 过滤冲突文件
                        if !ConflictFileFilter.isConflictFile(path) {
                            remoteEntries[path] = meta
                        }
                    case .deleted(_):
                        remoteDeletedPaths.append(path)
                    }
                }
            case .files(_, let entriesRaw, let deletedPaths):
                // 旧格式：兼容处理
                remoteEntries = ConflictFileFilter.filterConflictFiles(entriesRaw)
                remoteDeletedPaths = deletedPaths
                // 转换为统一状态格式
                for (path, meta) in remoteEntries {
                    remoteStates[path] = .exists(meta)
                }
                for path in remoteDeletedPaths {
                    // 创建删除记录（使用当前时间，因为旧格式没有删除时间信息）
                    // 尝试从远程获取删除记录的 Vector Clock，如果没有则创建新的
                    let currentVC = VectorClock()
                    let deletionRecord = DeletionRecord(
                        deletedAt: Date(),
                        deletedBy: peerID,
                        vectorClock: currentVC
                    )
                    remoteStates[path] = .deleted(deletionRecord)
                    // 注意：这里简化处理，实际应该从远程获取删除记录的 Vector Clock
                }
            default:
                AppLogger.syncPrint("[SyncEngine] ❌ [performSync] filesRes 不是 files 或 filesV2 类型")
                // 记录错误日志
                let log = SyncLog(
                    syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional,
                    bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(),
                    errorMessage: "获取远程文件列表失败：响应类型错误")
                try? StorageManager.shared.addSyncLog(log)
                return
            }

            // 获取本地状态存储
            let localStateStore = syncManager.getFileStateStore(for: syncID)

            // 构建本地状态映射（用于决策）
            var localStates: [String: FileState] = [:]
            for (path, meta) in localMetadata {
                if !ConflictFileFilter.isConflictFile(path) {
                    localStates[path] = .exists(meta)
                }
            }
            // 添加本地删除记录
            let localDeletedPaths = localStateStore.getDeletedPaths()
            for path in localDeletedPaths {
                if let state = localStateStore.getState(for: path) {
                    localStates[path] = state
                }
            }

            let myPeerID = await MainActor.run { syncManager.p2pNode.peerID?.b58String ?? "" }
            var totalOps = 0
            var completedOps = 0
            var syncedFiles: [SyncLog.SyncedFileInfo] = []
            var pendingTransfersRemaining = 0

            func registerPendingTransfers(_ count: Int) {
                guard count > 0 else { return }
                pendingTransfersRemaining += count
                syncManager.addPendingTransfers(count)
            }

            func markTransferCompleted() {
                guard pendingTransfersRemaining > 0 else { return }
                pendingTransfersRemaining -= 1
                syncManager.completePendingTransfers()
            }

            func cleanupPendingTransfers() {
                if pendingTransfersRemaining > 0 {
                    syncManager.completePendingTransfers(pendingTransfersRemaining)
                    pendingTransfersRemaining = 0
                }
            }

            // 定义下载和上传决策函数
            enum DownloadAction {
                case skip
                case overwrite
                case conflict
            }

            /// 决定下载操作（使用 VectorClockManager 统一决策逻辑）
            /// 决定下载操作（使用 VectorClockManager 统一决策逻辑）
            func downloadAction(remote: FileMetadata, local: FileMetadata?, path: String) async
                -> DownloadAction
            {
                // 重要：如果文件已删除（在 deletedSet 中），需要比较 Vector Clock
                // 如果远程的 VC 比本地删除记录的 VC 更新（或无关/冲突），则可能是文件被重新创建，需要下载
                if deletedSet.contains(path) {
                    let stateStore = await MainActor.run {
                        syncManager.getFileStateStore(for: syncID)
                    }
                    if let localState = stateStore.getState(for: path),
                        case .deleted(let deletionRecord) = localState
                    {
                        let comparison = remote.vectorClock?.compare(to: deletionRecord.vectorClock)

                        // 如果远程 VC <= 本地删除 VC，说明远程文件是旧版本，应跳过
                        if comparison == .antecedent || comparison == .equal {
                            AppLogger.syncPrint(
                                "[SyncEngine] ⏭️ [downloadAction] 文件已删除且远程版本较旧，跳过下载: 路径=\(path)")
                            return .skip
                        }

                        // 如果远程 VC > 本地删除 VC，说明是在删除后重新创建的，应该下载
                        // 如果是并发（concurrent），也应该作为冲突保留（下载）
                        AppLogger.syncPrint(
                            "[SyncEngine] 🔄 [downloadAction] 文件虽有删除记录但远程版本更新/冲突，允许下载: 路径=\(path)")
                        // Proceed to normal decision logic below
                    } else {
                        // 如果没有详细删除记录（旧格式），保守策略：跳过下载
                        AppLogger.syncPrint(
                            "[SyncEngine] ⏭️ [downloadAction] 文件已删除（无VC记录），跳过下载: 路径=\(path)")
                        return .skip
                    }
                }

                let localVC = local?.vectorClock
                let remoteVC = remote.vectorClock
                let localHash = local?.hash ?? ""
                let remoteHash = remote.hash

                let decision = VectorClockManager.decideSyncAction(
                    localVC: localVC,
                    remoteVC: remoteVC,
                    localHash: localHash,
                    remoteHash: remoteHash,
                    localMtime: local?.mtime,
                    remoteMtime: remote.mtime,
                    direction: .download
                )

                switch decision {
                case .skip:
                    return .skip
                case .overwriteLocal:
                    return .overwrite
                case .overwriteRemote, .uncertain:
                    // 下载方向不应该出现 overwriteRemote
                    // uncertain 情况保守处理为冲突
                    if decision == .uncertain {
                        AppLogger.syncPrint(
                            "[SyncEngine] ⚠️ [downloadAction] 无法确定同步方向，保存为冲突文件: 路径=\(path)")
                    }
                    return .conflict
                case .conflict:
                    AppLogger.syncPrint(
                        "[SyncEngine] ⚠️ [downloadAction] Vector Clock 并发冲突，保存为冲突文件: 路径=\(path)")
                    return .conflict
                }
            }

            /// 决定是否上传（使用 VectorClockManager 统一决策逻辑）
            ///
            /// 注意：此函数已被重构，冲突检测现在在上层统一处理。
            /// 此函数保留用于 FileTransfer 等需要简单布尔判断的场景。
            nonisolated func shouldUpload(local: FileMetadata, remote: FileMetadata?, path: String)
                -> Bool
            {
                let localVC = local.vectorClock
                let remoteVC = remote?.vectorClock
                let localHash = local.hash
                let remoteHash = remote?.hash ?? ""

                let decision = VectorClockManager.decideSyncAction(
                    localVC: localVC,
                    remoteVC: remoteVC,
                    localHash: localHash,
                    remoteHash: remoteHash,
                    localMtime: local.mtime,
                    remoteMtime: remote?.mtime,
                    direction: .upload
                )

                switch decision {
                case .skip, .overwriteLocal:
                    return false
                case .overwriteRemote, .uncertain:
                    // uncertain 情况采用本地优先策略
                    return true
                case .conflict:
                    // 冲突情况：在上层逻辑中统一处理，这里返回 false 避免重复处理
                    // 注意：FileTransfer 中使用此函数时，冲突会在上层被检测到并单独处理
                    return false
                }
            }

            // 合并已删除的文件集合：包括之前记录的删除和本次检测到的本地删除
            var deletedSet = syncManager.deletedPaths(for: syncID)
            deletedSet.formUnion(locallyDeleted)  // 确保包含本次检测到的本地删除

            // 处理远程的删除记录（tombstones）：如果远程有删除记录，说明这些文件已被删除
            // 需要删除本地文件并更新 deletedSet，防止已删除的文件被重新上传
            let remoteDeletedSet = Set(remoteDeletedPaths)
            if !remoteDeletedSet.isEmpty {
                AppLogger.syncPrint("[SyncEngine] 📋 收到远程删除记录: \(remoteDeletedSet.count) 个文件")
                let myPeerID = await MainActor.run { syncManager.p2pNode.peerID?.b58String ?? "" }

                for deletedPath in remoteDeletedSet {
                    // 获取远程删除记录（如果使用新格式）
                    let remoteState = remoteStates[deletedPath]
                    let remoteDeletionRecord = remoteState?.deletionRecord

                    // 重要：如果本地文件存在，需要比较 Vector Clock，而不是直接删除
                    // 如果文件是在删除之后重新创建的（VC 更新），应该保留文件
                    let fileURL = currentFolder.localPath.appendingPathComponent(deletedPath)
                    if fileManager.fileExists(atPath: fileURL.path) {
                        // 检查文件是否是新文件（在 currentPaths 中但不在 lastKnown 中）
                        // 如果是新文件，说明是在删除之后重新创建的，应该保留
                        let isNewFile =
                            currentPaths.contains(deletedPath) && !lastKnown.contains(deletedPath)

                        // 获取本地文件的元数据（包括 Vector Clock）
                        if let localMeta = localMetadata[deletedPath],
                            let remoteDel = remoteDeletionRecord
                        {
                            // 如果文件是新文件，或者文件的 VC 更新，保留文件
                            if isNewFile {
                                // 新文件：保留文件并清除删除记录
                                AppLogger.syncPrint(
                                    "[SyncEngine] ✅ 保留新文件（文件在删除之后重新创建）: \(deletedPath)")
                                // 为新文件创建 Vector Clock（如果还没有）
                                if localMeta.vectorClock == nil {
                                    var newVC = VectorClock()
                                    newVC.increment(for: myPeerID)
                                    VectorClockManager.saveVectorClock(
                                        folderID: folderID, syncID: syncID, path: deletedPath,
                                        vc: newVC)
                                }
                                // 清除本地删除记录（如果存在）
                                let stateStore = await MainActor.run {
                                    syncManager.getFileStateStore(for: syncID)
                                }
                                if let localState = stateStore.getState(for: deletedPath),
                                    case .deleted = localState
                                {
                                    stateStore.removeState(path: deletedPath)
                                    deletedSet.remove(deletedPath)
                                }
                            } else if let localVC = localMeta.vectorClock {
                                // 比较删除记录的 VC 和文件的 VC
                                let comparison = remoteDel.vectorClock.compare(to: localVC)
                                switch comparison {
                                case .successor, .equal:
                                    // 删除记录的 VC 更新或相等，删除本地文件
                                    AppLogger.syncPrint(
                                        "[SyncEngine] 🗑️ 删除本地文件（根据远程删除记录，VC 更新）: \(deletedPath)")
                                    await MainActor.run {
                                        syncManager.deleteFileAtomically(
                                            path: deletedPath, syncID: syncID, peerID: myPeerID)
                                    }
                                case .antecedent:
                                    // 删除记录的 VC 更旧，文件是在删除之后重新创建的，保留文件并清除删除记录
                                    AppLogger.syncPrint(
                                        "[SyncEngine] ✅ 保留文件（文件 VC 更新，删除记录 VC 更旧）: \(deletedPath)")
                                    // 清除本地删除记录（如果存在）
                                    let stateStore = await MainActor.run {
                                        syncManager.getFileStateStore(for: syncID)
                                    }
                                    if let localState = stateStore.getState(for: deletedPath),
                                        case .deleted = localState
                                    {
                                        stateStore.removeState(path: deletedPath)
                                        deletedSet.remove(deletedPath)
                                    }
                                case .concurrent:
                                    // 并发冲突，保守处理：删除文件
                                    AppLogger.syncPrint(
                                        "[SyncEngine] ⚠️ 并发冲突，保守处理：删除文件: \(deletedPath)")
                                    await MainActor.run {
                                        syncManager.deleteFileAtomically(
                                            path: deletedPath, syncID: syncID, peerID: myPeerID)
                                    }
                                }
                            } else {
                                // 文件存在但没有 VC，保守处理：删除文件
                                AppLogger.syncPrint(
                                    "[SyncEngine] 🗑️ 删除本地文件（根据远程删除记录，文件没有 VC）: \(deletedPath)")
                                await MainActor.run {
                                    syncManager.deleteFileAtomically(
                                        path: deletedPath, syncID: syncID, peerID: myPeerID)
                                }
                            }
                        } else if isNewFile {
                            // 新文件但没有元数据，创建元数据并保留文件
                            AppLogger.syncPrint("[SyncEngine] ✅ 保留新文件（新文件，创建 VC）: \(deletedPath)")
                            // 为新文件创建 Vector Clock
                            var newVC = VectorClock()
                            newVC.increment(for: myPeerID)
                            VectorClockManager.saveVectorClock(
                                folderID: folderID, syncID: syncID, path: deletedPath, vc: newVC)
                            // 清除本地删除记录（如果存在）
                            let stateStore = await MainActor.run {
                                syncManager.getFileStateStore(for: syncID)
                            }
                            if let localState = stateStore.getState(for: deletedPath),
                                case .deleted = localState
                            {
                                stateStore.removeState(path: deletedPath)
                                deletedSet.remove(deletedPath)
                            }
                        } else {
                            // 如果无法获取 VC 且不是新文件，保守处理：删除文件
                            AppLogger.syncPrint(
                                "[SyncEngine] 🗑️ 删除本地文件（根据远程删除记录，无法比较 VC）: \(deletedPath)")
                            await MainActor.run {
                                syncManager.deleteFileAtomically(
                                    path: deletedPath, syncID: syncID, peerID: myPeerID)
                            }
                        }
                    } else {
                        // 如果本地没有文件，合并删除记录
                        let stateStore = await MainActor.run {
                            syncManager.getFileStateStore(for: syncID)
                        }
                        let localState = stateStore.getState(for: deletedPath)

                        if let remoteDel = remoteDeletionRecord {
                            // 有远程删除记录，合并 Vector Clock
                            let localVC = localState?.vectorClock ?? VectorClock()
                            let mergedVC = VectorClockManager.mergeVectorClocks(
                                localVC: localVC,
                                remoteVC: remoteDel.vectorClock
                            )

                            // 创建合并后的删除记录（使用更早的删除时间）
                            let deletionRecord = DeletionRecord(
                                deletedAt: min(
                                    remoteDel.deletedAt,
                                    localState?.deletionRecord?.deletedAt ?? remoteDel.deletedAt),
                                deletedBy: remoteDel.deletedBy,  // 使用远程的删除者
                                vectorClock: mergedVC
                            )

                            stateStore.setDeleted(path: deletedPath, record: deletionRecord)
                            VectorClockManager.saveVectorClock(
                                folderID: folderID, syncID: syncID, path: deletedPath, vc: mergedVC)
                        } else {
                            // 没有远程删除记录（旧格式），创建新的删除记录
                            let currentVC =
                                VectorClockManager.getVectorClock(
                                    folderID: folderID, syncID: syncID, path: deletedPath)
                                ?? VectorClock()
                            var updatedVC = currentVC
                            updatedVC.increment(for: myPeerID)

                            let deletionRecord = DeletionRecord(
                                deletedAt: Date(),
                                deletedBy: myPeerID,
                                vectorClock: updatedVC
                            )

                            stateStore.setDeleted(path: deletedPath, record: deletionRecord)
                            VectorClockManager.saveVectorClock(
                                folderID: folderID, syncID: syncID, path: deletedPath, vc: updatedVC
                            )
                        }
                    }

                    // 更新 deletedSet，确保这个文件不会被上传
                    deletedSet.insert(deletedPath)
                    // 如果这个文件在本地元数据中，从上传列表中排除
                    if localMetadata.keys.contains(deletedPath) {
                        AppLogger.syncPrint("[SyncEngine] ⚠️ 阻止上传已删除的文件: \(deletedPath)")
                    }
                }
                // 更新持久化的删除记录（在 deletedSet 更新后）
                syncManager.updateDeletedPaths(deletedSet, for: syncID)
            }

            // 清理已确认删除的文件（远程也没有了）
            // 重要：在多客户端场景下，删除记录的清理需要更保守的策略
            // 问题：如果只检查单个远程客户端就清理删除记录，其他客户端可能还没有收到删除记录
            // 解决方案：删除记录应该保留更长时间（至少7天），确保所有客户端都有机会收到删除记录
            //
            // 当前策略：只从 deletedSet 中移除已确认的删除，但不立即清理 FileStateStore 中的删除记录
            // FileStateStore 中的删除记录会通过 cleanupExpiredDeletions 定期清理（7天后）
            let confirmed = deletedSet.filter { path in
                // 文件不在远程文件列表中
                let notInRemoteFiles = !remoteEntries.keys.contains(path)
                // 文件不在远程删除记录中（如果使用新格式）
                let notInRemoteDeleted = !remoteDeletedPaths.contains(path)
                // 只有当文件不在远程文件列表中，且不在远程删除记录中时，才确认删除
                return notInRemoteFiles && notInRemoteDeleted
            }

            // 重要：只从 deletedSet 中移除，但不立即清理 FileStateStore 中的删除记录
            // 这样可以确保删除记录保留更长时间，让所有客户端都有机会收到
            for p in confirmed {
                deletedSet.remove(p)
                // 同时从 locallyDeleted 中移除（如果存在），因为远程已经确认删除
                locallyDeleted.remove(p)
                // 注意：不立即清理 FileStateStore 中的删除记录
                // 删除记录会通过 cleanupExpiredDeletions 定期清理（7天后）
                // 这样可以确保所有客户端都有机会收到删除记录
                AppLogger.syncPrint(
                    "[SyncEngine] ✅ 删除已确认（从 deletedSet 移除）: \(p) (远程文件已不存在且不在远程删除记录中，但保留删除记录7天)")
            }

            // 更新 deletedSet（即使为空也更新，确保状态一致）
            if deletedSet.isEmpty {
                syncManager.removeDeletedPaths(for: syncID)
            } else {
                syncManager.updateDeletedPaths(deletedSet, for: syncID)
            }

            // 定期清理过期的删除记录（7天后）
            // 这样可以确保删除记录保留足够长时间，让所有客户端都有机会收到
            let stateStore = syncManager.getFileStateStore(for: syncID)
            stateStore.cleanupExpiredDeletions(expirationTime: 7 * 24 * 60 * 60) { path in
                // 检查是否所有在线客户端都已确认删除
                // 这里简化处理：如果删除记录超过7天，就清理
                // 这样可以确保删除记录保留足够长时间，让所有客户端都有机会收到
                return true  // 7天后自动清理
            }

            // 3. Download phase
            var changedFilesSet: Set<String> = []
            var conflictFilesSet: Set<String> = []
            var changedFiles: [(String, FileMetadata)] = []
            var conflictFiles: [(String, FileMetadata)] = []

            if mode == .twoWay || mode == .downloadOnly {
                // 合并所有路径（本地和远程）
                // 重要：也要包含 remoteDeletedPaths，确保删除记录被检查
                var allPaths = Set(remoteStates.keys).union(Set(localStates.keys))
                allPaths.formUnion(Set(remoteDeletedPaths))

                for path in allPaths {
                    // 重要：排除冲突文件（冲突文件不应该被同步，避免无限循环）
                    if ConflictFileFilter.isConflictFile(path) {
                        continue
                    }

                    // 跳过已处理的文件
                    if changedFilesSet.contains(path) || conflictFilesSet.contains(path) {
                        continue
                    }

                    // 重要：跳过重命名的旧路径（旧路径会在删除阶段处理，不应该下载）
                    if renamedFiles.keys.contains(path) {
                        AppLogger.syncPrint("[SyncEngine] ⏭️ [download] 跳过重命名的旧路径: 路径=\(path)")
                        continue
                    }

                    // 获取本地和远程状态
                    let localState = localStates[path]
                    var remoteState = remoteStates[path]

                    // 重要：如果路径在 remoteDeletedPaths 中但不在 remoteStates 中，
                    // 需要确保 remoteState 包含删除记录，以便 SyncDecisionEngine 能正确比较 VC
                    if remoteState == nil && remoteDeletedPaths.contains(path) {
                        // 从 remoteStates 中查找删除记录（应该已经在构建时包含了）
                        // 如果还是没有，说明是旧格式，需要创建删除记录
                        // 但这种情况应该已经在构建 remoteStates 时处理了
                        // 这里再次检查，确保 remoteState 不为 nil
                        if let state = remoteStates[path] {
                            remoteState = state
                        }
                    }

                    // 使用统一的决策引擎（它会正确比较 VC）
                    // SyncDecisionEngine 会正确处理删除记录和文件 VC 的比较
                    // 重要：先让 SyncDecisionEngine 做决策，因为它需要比较删除记录的 VC 和文件的 VC
                    // 对于删除-修改冲突，即使文件在 deletedSet 中，也应该生成冲突文件
                    let action = SyncDecisionEngine.decideSyncAction(
                        localState: localState,
                        remoteState: remoteState,
                        path: path
                    )

                    switch action {
                    case .skip:
                        // 无需操作
                        break

                    case .download:
                        // 下载文件（覆盖本地）
                        // 检查删除记录，但依赖 SyncDecisionEngine 的决策
                        // 如果 SyncDecisionEngine 决定下载，说明远程版本比本地删除记录更新（或重新创建）
                        // 因此这里不做简单的 deletedSet 检查，而是允许下载

                        // 双重检查：如果本地状态是 .deleted，且 SyncDecisionEngine 决定 .download
                        // 这意味着远程文件的 VC > 本地删除记录的 VC -> 这是合法的重新创建/恢复

                        if let remoteMeta = remoteState?.metadata {
                            if deletedSet.contains(path) {
                                AppLogger.syncPrint(
                                    "[SyncEngine] 🔄 [download] 从删除状态恢复文件（VC更新）: 路径=\(path)")
                                // 从 deletedSet 中移除，防止后续误判
                                deletedSet.remove(path)
                            }
                            changedFilesSet.insert(path)
                            changedFiles.append((path, remoteMeta))
                        }

                    case .deleteLocal:
                        // 删除本地文件（远程已删除）
                        if remoteState?.isDeleted == true || remoteDeletedPaths.contains(path) {
                            await MainActor.run {
                                syncManager.deleteFileAtomically(
                                    path: path, syncID: syncID, peerID: myPeerID)
                            }
                        }

                    case .conflict:
                        // 冲突：保存远程版本为冲突文件
                        // 重要：对于删除-修改冲突，即使文件在 deletedSet 中，也应该生成冲突文件
                        // 因为 SyncDecisionEngine 已经检测到并发冲突（删除记录的 VC 和文件的 VC 并发）
                        // 这种情况下，需要保存远程版本为冲突文件，让用户决定保留哪个版本
                        if let remoteMeta = remoteState?.metadata {
                            // 检查是否是删除-修改冲突（本地有删除记录，远程有文件）
                            let isDeleteModifyConflict =
                                localState?.isDeleted == true && remoteState?.isDeleted == false

                            if isDeleteModifyConflict {
                                // 删除-修改冲突：即使文件在 deletedSet 中，也生成冲突文件
                                AppLogger.syncPrint(
                                    "[SyncEngine] ⚠️ [download] 删除-修改冲突，生成冲突文件: 路径=\(path), deletedSet=\(deletedSet.contains(path))"
                                )
                                conflictFilesSet.insert(path)
                                conflictFiles.append((path, remoteMeta))
                            } else if deletedSet.contains(path) || remoteDeletedPaths.contains(path)
                            {
                                // 其他冲突但文件已删除，跳过
                                AppLogger.syncPrint(
                                    "[SyncEngine] ⏭️ [download] 冲突但文件已删除，跳过: 路径=\(path)")
                                continue
                            } else {
                                // 普通冲突（双方都修改），生成冲突文件
                                AppLogger.syncPrint(
                                    "[SyncEngine] ⚠️ [download] 普通冲突，生成冲突文件: 路径=\(path)")
                                conflictFilesSet.insert(path)
                                conflictFiles.append((path, remoteMeta))
                            }
                        } else {
                            AppLogger.syncPrint(
                                "[SyncEngine] ⚠️ [download] 冲突但 remoteMeta 为空: 路径=\(path), localDeleted=\(localState?.isDeleted ?? false), remoteDeleted=\(remoteState?.isDeleted ?? false)"
                            )
                        }

                    case .uncertain:
                        // 不确定：检查删除记录后再决定
                        if deletedSet.contains(path) || remoteDeletedPaths.contains(path) {
                            AppLogger.syncPrint(
                                "[SyncEngine] ⏭️ [download] 不确定但文件已删除，跳过: 路径=\(path)")
                            continue
                        }
                        // 如果远程存在，下载（保守策略）
                        if let remoteMeta = remoteState?.metadata {
                            AppLogger.syncPrint("[SyncEngine] ⚠️ [download] 无法确定同步方向: 路径=\(path)")
                            changedFilesSet.insert(path)
                            changedFiles.append((path, remoteMeta))
                        }

                    case .upload, .deleteRemote:
                        // 下载阶段不应该出现这些操作
                        break
                    }
                }
            }
            totalOps += changedFiles.count + conflictFiles.count
            AppLogger.syncPrint(
                "[SyncEngine] 📊 下载阶段: 需要下载=\(changedFiles.count), 冲突=\(conflictFiles.count)")

            // 4. Upload phase - 检测上传冲突
            var filesToUploadSet: Set<String> = []
            var filesToUpload: [(String, FileMetadata)] = []
            var uploadConflictFiles: [(String, FileMetadata)] = []  // 上传时的冲突文件（需要先保存远程版本）
            var deleteRemotePaths: Set<String> = []

            if mode == .twoWay || mode == .uploadOnly {
                // 合并所有路径（本地和远程）
                // 重要：也要包含 remoteDeletedPaths，确保删除记录被检查
                var allPaths = Set(localStates.keys).union(Set(remoteStates.keys))
                allPaths.formUnion(Set(remoteDeletedPaths))

                for path in allPaths {
                    // 重要：排除冲突文件（冲突文件不应该被同步，避免无限循环）
                    if ConflictFileFilter.isConflictFile(path) {
                        continue
                    }

                    // 跳过重命名的旧路径（旧路径会在删除阶段处理，新路径会正常上传）
                    if renamedFiles.keys.contains(path) {
                        continue
                    }

                    // 跳过已处理的文件
                    if filesToUploadSet.contains(path) {
                        continue
                    }

                    // 获取本地和远程状态
                    let localState = localStates[path]
                    var remoteState = remoteStates[path]

                    // 重要：如果路径在 remoteDeletedPaths 中但不在 remoteStates 中，
                    // 需要确保 remoteState 包含删除记录，以便 SyncDecisionEngine 能正确比较 VC
                    if remoteState == nil && remoteDeletedPaths.contains(path) {
                        // 从 remoteStates 中查找删除记录（应该已经在构建时包含了）
                        if let state = remoteStates[path] {
                            remoteState = state
                        }
                    }

                    // 使用统一的决策引擎（它会正确比较 VC）
                    // SyncDecisionEngine 会正确处理删除记录和文件 VC 的比较
                    // 重要：先让 SyncDecisionEngine 做决策，因为它需要比较删除记录的 VC 和文件的 VC
                    // 对于删除-修改冲突，即使文件在 deletedSet 中，也应该生成冲突文件
                    let action = SyncDecisionEngine.decideSyncAction(
                        localState: localState,
                        remoteState: remoteState,
                        path: path
                    )

                    switch action {
                    case .skip:
                        // 无需操作
                        break

                    case .upload:
                        // 上传文件（覆盖远程）
                        // 检查删除记录（双重保险），但允许冲突情况通过
                        if deletedSet.contains(path) || remoteDeletedPaths.contains(path) {
                            AppLogger.syncPrint("[SyncEngine] ⏭️ [upload] 文件已删除，跳过上传: 路径=\(path)")
                            continue
                        }
                        if let localMeta = localState?.metadata {
                            filesToUploadSet.insert(path)
                            filesToUpload.append((path, localMeta))
                        }

                    case .deleteRemote:
                        // 删除远程文件（本地已删除）
                        deleteRemotePaths.insert(path)
                        break

                    case .conflict:
                        // 冲突：需要先保存远程版本为冲突文件，然后再上传本地版本
                        // 重要：对于删除-修改冲突，即使文件在 deletedSet 中，也应该生成冲突文件
                        // 因为 SyncDecisionEngine 已经检测到并发冲突（删除记录的 VC 和文件的 VC 并发）
                        if let localMeta = localState?.metadata {
                            // 检查是否是删除-修改冲突（本地有文件，远程有删除记录）
                            let isDeleteModifyConflict =
                                localState?.isDeleted == false && remoteState?.isDeleted == true

                            if isDeleteModifyConflict {
                                // 删除-修改冲突：即使文件在 deletedSet 中，也生成冲突文件
                                AppLogger.syncPrint(
                                    "[SyncEngine] ⚠️ [upload] 删除-修改冲突，生成冲突文件: 路径=\(path)")
                                if let remoteMeta = remoteState?.metadata {
                                    uploadConflictFiles.append((path, remoteMeta))
                                }
                                filesToUploadSet.insert(path)
                                filesToUpload.append((path, localMeta))
                            } else if deletedSet.contains(path) || remoteDeletedPaths.contains(path)
                            {
                                // 其他冲突但文件已删除，跳过
                                AppLogger.syncPrint(
                                    "[SyncEngine] ⏭️ [upload] 冲突但文件已删除，跳过: 路径=\(path)")
                                continue
                            } else {
                                // 普通冲突（双方都修改），先保存远程版本为冲突文件，然后上传本地版本
                                if let remoteMeta = remoteState?.metadata {
                                    uploadConflictFiles.append((path, remoteMeta))
                                }
                                filesToUploadSet.insert(path)
                                filesToUpload.append((path, localMeta))
                            }
                        }

                    case .uncertain:
                        // 无法确定：检查删除记录后再决定
                        // 如果文件已删除，不应该上传
                        if deletedSet.contains(path) || remoteDeletedPaths.contains(path) {
                            AppLogger.syncPrint("[SyncEngine] ⏭️ [upload] 不确定但文件已删除，跳过: 路径=\(path)")
                            continue
                        }
                        // 如果本地有文件，但远程没有状态，且不在删除记录中，可能是新文件，应该上传
                        if let localMeta = localState?.metadata {
                            AppLogger.syncPrint(
                                "[SyncEngine] ⚠️ [upload] 无法确定同步方向，采用本地优先上传策略: 路径=\(path)")
                            filesToUploadSet.insert(path)
                            filesToUpload.append((path, localMeta))
                        }

                    case .download, .deleteLocal:
                        // 上传阶段不应该出现这些操作
                        break
                    }
                }
            }
            totalOps += filesToUpload.count + uploadConflictFiles.count
            AppLogger.syncPrint(
                "[SyncEngine] 📊 上传阶段: 需要上传=\(filesToUpload.count), 上传冲突=\(uploadConflictFiles.count)"
            )

            // 处理删除和重命名：重命名需要先在远程删除旧路径，然后上传新路径
            var toDeleteMap: [String: VectorClock?] = [:]
            let pathsToDelete =
                (mode == .twoWay || mode == .uploadOnly)
                ? locallyDeleted.union(deleteRemotePaths) : []

            for path in pathsToDelete {
                toDeleteMap[path] = VectorClockManager.getVectorClock(
                    folderID: currentFolder.id, syncID: syncID, path: path)
            }

            // 重命名操作：需要在远程删除旧路径
            if mode == .twoWay || mode == .uploadOnly {
                for oldPath in renamedFiles.keys {
                    if toDeleteMap[oldPath] == nil {
                        toDeleteMap[oldPath] = VectorClockManager.getVectorClock(
                            folderID: currentFolder.id, syncID: syncID, path: oldPath)
                    }
                }
            }

            if !toDeleteMap.isEmpty {
                totalOps += toDeleteMap.count
            }

            if totalOps > 0 {
                syncManager.updateFolderStatus(
                    currentFolder.id, status: .syncing, message: "准备同步 \(totalOps) 个操作...",
                    progress: 0.2)
            }

            // 重要：先执行删除操作，确保远程删除后再进行下载，避免下载已删除的文件
            if !toDeleteMap.isEmpty {
                syncManager.updateFolderStatus(
                    currentFolder.id, status: .syncing, message: "正在删除 \(toDeleteMap.count) 个文件...",
                    progress: Double(completedOps) / Double(max(totalOps, 1)))

                let delRes: SyncResponse = try await syncManager.sendSyncRequest(
                    .deleteFiles(syncID: syncID, paths: toDeleteMap),
                    to: peer,
                    peerID: peerID,
                    timeout: 90.0,
                    maxRetries: 3,
                    folder: currentFolder
                )

                if case .deleteAck = delRes {
                    // 删除请求已发送成功
                    // 重要：不要立即从 deletedSet 中移除，因为：
                    // 1. deleteAck 只表示远程收到了删除请求，不一定表示文件已真正删除
                    // 2. 应该等到下次同步时，通过检查远程文件列表确认文件已不存在后再移除
                    // 3. 这样可以防止删除请求成功后，但远程文件还在的情况下，文件被重新下载

                    // 获取当前设备的 PeerID（用于创建删除记录）
                    let myPeerID = await MainActor.run {
                        syncManager.p2pNode.peerID?.b58String ?? ""
                    }

                    for rel in toDeleteMap.keys {
                        // 使用原子性删除操作
                        await MainActor.run {
                            syncManager.deleteFileAtomically(
                                path: rel, syncID: syncID, peerID: myPeerID)
                        }

                        let fileName = (rel as NSString).lastPathComponent
                        let pathDir = (rel as NSString).deletingLastPathComponent
                        let folderName =
                            pathDir.isEmpty ? nil : (pathDir as NSString).lastPathComponent

                        var fileSize: Int64 = 0
                        let fileURL = currentFolder.localPath.appendingPathComponent(rel)
                        if fileManager.fileExists(atPath: fileURL.path),
                            let attributes = try? fileManager.attributesOfItem(
                                atPath: fileURL.path),
                            let size = attributes[FileAttributeKey.size] as? Int64
                        {
                            fileSize = size
                        }

                        syncedFiles.append(
                            SyncLog.SyncedFileInfo(
                                path: rel,
                                fileName: fileName,
                                folderName: folderName,
                                size: fileSize,
                                operation: .delete
                            ))

                        // 注意：不从这里移除 deletedSet，让第 542-549 行的逻辑在下次同步时确认删除
                    }
                    completedOps += toDeleteMap.count

                    // 注意：不在这里更新 deletedPaths
                    // deletedSet 仍然包含已发送删除请求的文件，直到下次同步时确认远程文件已不存在
                    // 这样可以防止删除请求成功后，但远程文件还在的情况下，文件被重新下载
                    // deletedPaths 会在第 550-554 行统一更新
                } else {
                    // 删除失败，记录错误但不阻止后续操作
                    AppLogger.syncPrint("[SyncEngine] ⚠️ 删除操作失败，响应: \(delRes)")
                }
            }

            if totalOps == 0 {
                syncManager.lastKnownLocalPaths[syncID] = currentPaths
                syncManager.lastKnownMetadata[syncID] = localMetadata  // 保存当前元数据用于下次重命名检测

                // 原子性地保存文件夹快照（即使没有文件操作）
                await saveSnapshotAtomically(
                    syncID: syncID,
                    folderID: folderID,
                    metadata: localMetadata,
                    folderCount: 0,  // 这里不需要重新计算，使用占位值
                    totalSize: 0
                )
                syncManager.updateFolderStatus(
                    currentFolder.id, status: .synced, message: "Up to date", progress: 1.0)
                syncManager.syncIDManager.updateLastSyncedAt(syncID)
                syncManager.peerManager.updateOnlineStatus(peerID, isOnline: true)
                syncManager.updateDeviceCounts()
                // 记录成功日志（即使没有文件操作）
                let direction: SyncLog.Direction =
                    mode == .uploadOnly
                    ? .upload : (mode == .downloadOnly ? .download : .bidirectional)
                let log = SyncLog(
                    syncID: syncID, folderID: folderID, peerID: peerID, direction: direction,
                    bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(),
                    syncedFiles: nil)
                try? StorageManager.shared.addSyncLog(log)
                return
            }

            // 5. 统一下载阶段：普通下载 + 冲突文件（合并为单一 TaskGroup，提升并发利用率）
            var totalDownloadBytes: Int64 = 0
            var totalUploadBytes: Int64 = 0

            let filesToDownload = changedFiles.filter { path, _ in
                !locallyDeleted.contains(path) && !deletedSet.contains(path)
                    && !renamedFiles.keys.contains(path)
            }

            enum DownloadKind {
                case normal
                case conflict
            }
            var downloadItems: [(path: String, remoteMeta: FileMetadata, kind: DownloadKind)] = []
            for (p, m) in filesToDownload { downloadItems.append((p, m, .normal)) }
            for (p, m) in conflictFiles { downloadItems.append((p, m, .conflict)) }
            for (p, m) in uploadConflictFiles { downloadItems.append((p, m, .conflict)) }

            let transferOpsCount = downloadItems.count + filesToUpload.count
            if transferOpsCount > 0 {
                registerPendingTransfers(transferOpsCount)
            }
            defer { cleanupPendingTransfers() }

            await withTaskGroup(of: (Int64, SyncLog.SyncedFileInfo)?.self) { group in
                var activeDownloads = 0

                for item in downloadItems {
                    let (path, remoteMeta, kind) = (item.path, item.remoteMeta, item.kind)
                    if activeDownloads >= maxConcurrentTransfers {
                        let result = await group.next()
                        activeDownloads -= 1
                        if let result = result {
                            markTransferCompleted()
                            if let (bytes, fileInfo) = result {
                                totalDownloadBytes += bytes
                                syncedFiles.append(fileInfo)
                                completedOps += 1
                                await MainActor.run { syncManager.addDownloadBytes(bytes) }
                                await MainActor.run {
                                    syncManager.updateFolderStatus(
                                        currentFolder.id, status: .syncing,
                                        message: "下载完成: \(completedOps)/\(totalOps)",
                                        progress: Double(completedOps) / Double(max(totalOps, 1)))
                                }
                            }
                        }
                    }
                    activeDownloads += 1

                    group.addTask { [weak self] in
                        guard let self = self else { return nil }
                        let latestFolder = await MainActor.run {
                            syncManager.folders.first(where: { $0.id == folderID })
                        }
                        guard let latestFolder = latestFolder else { return nil }

                        switch kind {
                        case .normal:
                            let ft = await MainActor.run { self.fileTransfer }
                            guard let ft = ft else { return nil }
                            let localURL = latestFolder.localPath.appendingPathComponent(path)
                            var fileSize: Int64 = 0
                            if let attrs = try? FileManager.default.attributesOfItem(
                                atPath: localURL.path),
                                let s = attrs[.size] as? Int64
                            {
                                fileSize = s
                            }
                            do {
                                if fileSize >= self.chunkSyncThreshold {
                                    return try await ft.downloadFileWithChunks(
                                        path: path, remoteMeta: remoteMeta, folder: latestFolder,
                                        peer: peer, peerID: peerID, localMetadata: localMetadata)
                                } else {
                                    return try await ft.downloadFileFull(
                                        path: path, remoteMeta: remoteMeta, folder: latestFolder,
                                        peer: peer, peerID: peerID, localMetadata: localMetadata)
                                }
                            } catch {
                                AppLogger.syncPrint(
                                    "[SyncEngine] ❌ 下载文件失败: \(path) - \(error.localizedDescription)"
                                )
                                return nil
                            }

                        case .conflict:
                            let sm = await MainActor.run { self.syncManager }
                            guard let sm = sm else { return nil }
                            let fileName = (path as NSString).lastPathComponent
                            do {
                                let dataRes: SyncResponse = try await sm.sendSyncRequest(
                                    .getFileData(syncID: syncID, path: path),
                                    to: peer, peerID: peerID, timeout: 180.0, maxRetries: 3,
                                    folder: latestFolder)
                                guard case .fileData(_, _, let data) = dataRes else { return nil }
                                let pathDir = (path as NSString).deletingLastPathComponent
                                let parent =
                                    pathDir.isEmpty
                                    ? latestFolder.localPath
                                    : latestFolder.localPath.appendingPathComponent(pathDir)
                                let base = (fileName as NSString).deletingPathExtension
                                let ext = (fileName as NSString).pathExtension
                                let suffix = ext.isEmpty ? "" : ".\(ext)"
                                let conflictName =
                                    "\(base).conflict.\(String(peerID.prefix(8))).\(Int(remoteMeta.mtime.timeIntervalSince1970))\(suffix)"
                                let conflictURL = parent.appendingPathComponent(conflictName)
                                let fm = FileManager.default
                                if !fm.fileExists(atPath: parent.path) {
                                    try fm.createDirectory(
                                        at: parent, withIntermediateDirectories: true)
                                }
                                guard fm.isWritableFile(atPath: parent.path) else {
                                    throw NSError(
                                        domain: "SyncEngine", code: -1,
                                        userInfo: [
                                            NSLocalizedDescriptionKey: "没有写入权限: \(parent.path)"
                                        ])
                                }
                                try data.write(to: conflictURL)
                                let relConflict =
                                    pathDir.isEmpty ? conflictName : "\(pathDir)/\(conflictName)"
                                let cf = ConflictFile(
                                    syncID: syncID, relativePath: path, conflictPath: relConflict,
                                    remotePeerID: peerID)
                                try? StorageManager.shared.addConflict(cf)
                                let folderName =
                                    pathDir.isEmpty ? nil : (pathDir as NSString).lastPathComponent
                                return (
                                    Int64(data.count),
                                    SyncLog.SyncedFileInfo(
                                        path: path, fileName: fileName, folderName: folderName,
                                        size: Int64(data.count), operation: .conflict)
                                )
                            } catch {
                                AppLogger.syncPrint(
                                    "[SyncEngine] ❌ 下载/保存冲突文件失败: \(path) - \(error.localizedDescription)"
                                )
                                return nil
                            }
                        }
                    }
                }

                for await result in group {
                    markTransferCompleted()
                    if let (bytes, fileInfo) = result {
                        totalDownloadBytes += bytes
                        syncedFiles.append(fileInfo)
                        completedOps += 1
                        await MainActor.run { syncManager.addDownloadBytes(bytes) }
                        syncManager.updateFolderStatus(
                            currentFolder.id, status: .syncing,
                            message: "下载完成: \(completedOps)/\(totalOps)",
                            progress: Double(completedOps) / Double(max(totalOps, 1)))
                    }
                }
            }

            // 6. Upload files to remote - 并行上传
            await withTaskGroup(of: (Int64, SyncLog.SyncedFileInfo)?.self) { group in
                var activeUploads = 0

                for (path, localMeta) in filesToUpload {
                    if activeUploads >= maxConcurrentTransfers {
                        let result = await group.next()
                        activeUploads -= 1
                        if let result = result {
                            markTransferCompleted()
                            if let (bytes, fileInfo) = result {
                                totalUploadBytes += bytes
                                syncedFiles.append(fileInfo)
                                completedOps += 1

                                await MainActor.run {
                                    syncManager.addUploadBytes(bytes)
                                }
                                await MainActor.run {
                                    syncManager.updateFolderStatus(
                                        currentFolder.id, status: .syncing,
                                        message: "上传完成: \(completedOps)/\(totalOps)",
                                        progress: Double(completedOps)
                                            / Double(max(totalOps, 1)))
                                }
                            }
                        }
                    }

                    activeUploads += 1

                    group.addTask { [weak self] in
                        guard let self = self else { return nil }

                        let fileTransfer = await MainActor.run { self.fileTransfer }
                        guard let fileTransfer = fileTransfer else { return nil }

                        // 获取最新的 folder 对象
                        let latestFolder = await MainActor.run {
                            return syncManager.folders.first(where: { $0.id == folderID })
                        }
                        guard let latestFolder = latestFolder else { return nil }

                        do {
                            let fileURL = latestFolder.localPath.appendingPathComponent(path)
                            let resolvedURL = fileURL.resolvingSymlinksInPath()
                            let fileManager = FileManager.default

                            guard fileManager.fileExists(atPath: resolvedURL.path) else {
                                AppLogger.syncPrint("[SyncEngine] ⚠️ 文件不存在（跳过上传）: \(fileURL.path)")
                                return nil
                            }

                            // 检查是否为目录，如果是目录则跳过（目录不应该被上传）
                            var isDirectory: ObjCBool = false
                            if fileManager.fileExists(
                                atPath: resolvedURL.path, isDirectory: &isDirectory),
                                isDirectory.boolValue
                            {
                                AppLogger.syncPrint("[SyncEngine] ⏭️ 跳过目录上传: \(path)")
                                return nil
                            }

                            guard fileManager.isReadableFile(atPath: resolvedURL.path) else {
                                AppLogger.syncPrint("[SyncEngine] ⚠️ 文件无读取权限（跳过上传）: \(fileURL.path)")
                                return nil
                            }

                            let fileAttributes = try fileManager.attributesOfItem(
                                atPath: resolvedURL.path)
                            let fileSize = (fileAttributes[.size] as? Int64) ?? 0

                            if fileSize >= self.chunkSyncThreshold {
                                return try await fileTransfer.uploadFileWithChunks(
                                    path: path,
                                    localMeta: localMeta,
                                    folder: latestFolder,
                                    peer: peer,
                                    peerID: peerID,
                                    myPeerID: myPeerID,
                                    remoteEntries: remoteEntries,
                                    shouldUpload: shouldUpload
                                )
                            } else {
                                return try await fileTransfer.uploadFileFull(
                                    path: path,
                                    localMeta: localMeta,
                                    folder: latestFolder,
                                    peer: peer,
                                    peerID: peerID,
                                    myPeerID: myPeerID,
                                    remoteEntries: remoteEntries,
                                    shouldUpload: shouldUpload
                                )
                            }
                        } catch {
                            if (error as NSError).code == -2 {
                                return nil
                            }
                            AppLogger.syncPrint(
                                "[SyncEngine] ❌ 上传文件失败: \(path) - \(error.localizedDescription)")
                            return nil
                        }
                    }
                }

                for await result in group {
                    markTransferCompleted()
                    if let (bytes, fileInfo) = result {
                        totalUploadBytes += bytes
                        syncedFiles.append(fileInfo)
                        completedOps += 1

                        await MainActor.run {
                            syncManager.addUploadBytes(bytes)
                        }
                        syncManager.updateFolderStatus(
                            currentFolder.id, status: .syncing,
                            message: "上传完成: \(completedOps)/\(totalOps)",
                            progress: Double(completedOps) / Double(max(totalOps, 1)))
                    }
                }
            }

            // 同步完成后，重新计算本地状态并更新统计
            // 重要：使用最新的 folder 对象计算状态
            let (_, finalMetadata, finalFolderCount, finalTotalSize) =
                await folderStatistics.calculateFullState(for: currentFolder)
            let finalPaths = Set(finalMetadata.keys)
            syncManager.lastKnownLocalPaths[syncID] = finalPaths
            syncManager.lastKnownMetadata[syncID] = finalMetadata  // 保存当前元数据用于下次重命名检测

            // 原子性地保存文件夹快照（用于多端同步）
            await saveSnapshotAtomically(
                syncID: syncID,
                folderID: folderID,
                metadata: finalMetadata,
                folderCount: finalFolderCount,
                totalSize: finalTotalSize
            )

            // 更新统计值（同步后文件可能已变化）
            // 注意：SyncEngine 是 @MainActor，但这里需要确保在 MainActor 上下文中更新
            await MainActor.run {
                if let index = syncManager.folders.firstIndex(where: { $0.id == folderID }) {
                    var updatedFolder = syncManager.folders[index]
                    updatedFolder.fileCount = finalMetadata.count
                    updatedFolder.folderCount = finalFolderCount
                    updatedFolder.totalSize = finalTotalSize
                    syncManager.folders[index] = updatedFolder
                    syncManager.objectWillChange.send()

                    // 持久化保存统计信息更新
                    Task.detached {
                        do {
                            try StorageManager.shared.saveFolder(updatedFolder)
                        } catch {
                            AppLogger.syncPrint("[SyncEngine] ⚠️ 无法保存文件夹统计信息更新: \(error)")
                        }
                    }
                }
            }

            let totalBytes = totalDownloadBytes + totalUploadBytes
            AppLogger.syncPrint(
                "[SyncEngine] ✅ 同步完成: syncID=\(syncID), 下载=\(totalDownloadBytes) bytes, 上传=\(totalUploadBytes) bytes, 操作=\(totalOps)"
            )

            syncManager.updateFolderStatus(
                currentFolder.id, status: .synced, message: "同步完成", progress: 1.0)
            syncManager.syncIDManager.updateLastSyncedAt(syncID)
            syncManager.peerManager.updateOnlineStatus(peerID, isOnline: true)
            syncManager.updateDeviceCounts()
            let cooldownKey = "\(peerID):\(syncID)"
            syncManager.peerSyncCooldown[cooldownKey] = Date()

            let direction: SyncLog.Direction =
                mode == .uploadOnly ? .upload : (mode == .downloadOnly ? .download : .bidirectional)
            let log = SyncLog(
                syncID: syncID, folderID: folderID, peerID: peerID, direction: direction,
                bytesTransferred: totalBytes, filesCount: totalOps, startedAt: startedAt,
                completedAt: Date(), syncedFiles: syncedFiles.isEmpty ? nil : syncedFiles)
            try? StorageManager.shared.addSyncLog(log)
        } catch {
            let duration = Date().timeIntervalSince(startedAt)
            AppLogger.syncPrint("[SyncEngine] ❌ [performSync] 同步失败!")
            AppLogger.syncPrint("[SyncEngine]   文件夹: \(syncID)")
            AppLogger.syncPrint("[SyncEngine]   对等点: \(peerID.prefix(12))...")
            AppLogger.syncPrint("[SyncEngine]   耗时: \(String(format: "%.2f", duration)) 秒")
            AppLogger.syncPrint("[SyncEngine]   错误: \(error)")

            syncManager.removeFolderPeer(syncID, peerID: peerID)
            let errorMessage =
                error.localizedDescription.isEmpty ? "同步失败: \(error)" : error.localizedDescription
            syncManager.updateFolderStatus(
                currentFolder.id, status: .error, message: errorMessage,
                errorDetail: String(describing: error))

            let log = SyncLog(
                syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional,
                bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: nil,
                errorMessage: error.localizedDescription)
            do {
                try StorageManager.shared.addSyncLog(log)
            } catch {
                AppLogger.syncPrint("[SyncEngine] ⚠️ 无法保存同步日志: \(error)")
            }
        }
    }

    /// 原子性地保存文件夹快照
    private func saveSnapshotAtomically(
        syncID: String,
        folderID: UUID,
        metadata: [String: FileMetadata],
        folderCount: Int,
        totalSize: Int64
    ) async {
        guard let syncManager = syncManager else { return }

        // 获取文件大小信息（用于快照）
        var fileSizes: [String: Int64] = [:]
        if let currentFolder = syncManager.folders.first(where: { $0.id == folderID }) {
            let fileManager = FileManager.default
            for (path, _) in metadata {
                let fileURL = currentFolder.localPath.appendingPathComponent(path)
                if let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
                    let size = attrs[.size] as? Int64
                {
                    fileSizes[path] = size
                }
            }
        }

        // 创建快照
        let snapshot = FolderSnapshot.fromFileMetadata(
            syncID: syncID,
            folderID: folderID,
            metadata: metadata,
            fileSizes: fileSizes
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
