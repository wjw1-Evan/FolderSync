import Foundation

/// 表示一次同步会话的上下文状态
struct SyncSession {
    let syncID: String
    let folderID: UUID
    let peerID: String
    let startedAt: Date
    var folder: SyncFolder

    // 发现阶段结果
    var remoteHash: String?
    var remoteStates: [String: FileState] = [:]

    // 本地状态阶段结果
    var localMST: MerkleSearchTree?
    var localMetadata: [String: FileMetadata]?
    var locallyDeleted: Set<String> = []

    // 计划阶段结果
    var actions: [String: SyncDecisionEngine.SyncAction] = [:]

    // 统计和日志
    var bytesTransferred: Int64 = 0
    var filesSynced: [SyncLog.SyncedFileInfo] = []

    init(folder: SyncFolder, peerID: String) {
        self.syncID = folder.syncID
        self.folderID = folder.id
        self.peerID = peerID
        self.startedAt = Date()
        self.folder = folder
    }
}

extension SyncEngine {

    /// 发现阶段：获取远程状态
    func discoveryPhase(session: inout SyncSession) async throws {
        guard let syncManager = syncManager else { return }

        // 1. 获取远程 MST 根
        let rootRes = try await syncManager.p2pNode.sendRequest(
            .getMST(syncID: session.syncID),
            to: session.peerID
        )

        guard case .mstRoot(_, let remoteHash) = rootRes else {
            if case .error = rootRes {
                throw SyncError.remoteFolderMissing
            }
            throw SyncError.invalidResponse
        }
        session.remoteHash = remoteHash

        // 2. 获取远程文件列表
        let filesRes = try await syncManager.p2pNode.sendRequest(
            .getFiles(syncID: session.syncID),
            to: session.peerID
        )

        switch filesRes {
        case .filesV2(_, let states):
            session.remoteStates = states
        case .files(_, let entries, let deletedPaths):
            // 兼容性：转换旧格式
            var states: [String: FileState] = [:]
            for (path, meta) in entries {
                states[path] = .exists(meta)
            }
            for path in deletedPaths {
                states[path] = .deleted(
                    DeletionRecord(deletedBy: session.peerID, vectorClock: VectorClock()))
            }
            session.remoteStates = states
        default:
            throw SyncError.invalidResponse
        }
    }

    /// 本地状态阶段：分析本地文件变更、重命名和删除
    func localStatePhase(
        session: inout SyncSession, precomputed: (MerkleSearchTree, [String: FileMetadata])?
    ) async {
        guard let syncManager = syncManager, let folderStatistics = folderStatistics else { return }

        // 1. 计算/获取当前状态
        if let pre = precomputed {
            session.localMST = pre.0
            session.localMetadata = ConflictFileFilter.filterConflictFiles(pre.1)
        } else {
            let (mst, raw, _, _) = await folderStatistics.calculateFullState(for: session.folder)
            session.localMST = mst
            session.localMetadata = ConflictFileFilter.filterConflictFiles(raw)
        }

        let currentPaths = Set(session.localMetadata?.keys ?? [String: FileMetadata]().keys)
        let lastKnown = syncManager.lastKnownLocalPaths[session.syncID] ?? []
        let lastKnownMeta = syncManager.lastKnownMetadata[session.syncID] ?? [:]
        let isFirstSync = lastKnown.isEmpty

        if isFirstSync { return }

        // 2. 检测重命名和删除
        var candidates: [String: FileMetadata] = [:]  // disappeared candidates
        for path in lastKnown {
            if !currentPaths.contains(path) {
                if let oldMeta = lastKnownMeta[path] {
                    candidates[path] = oldMeta
                } else {
                    session.locallyDeleted.insert(path)
                }
            }
        }

        var newFiles: [String: FileMetadata] = [:]
        for path in currentPaths {
            if !lastKnown.contains(path) {
                if let meta = session.localMetadata?[path] {
                    newFiles[path] = meta
                }
            }
        }

        // 匹配重命名
        for (oldPath, oldMeta) in candidates {
            if let (newPath, _) = newFiles.first(where: { $0.value.hash == oldMeta.hash }) {
                VectorClockManager.migrateVectorClock(
                    folderID: session.folderID, syncID: session.syncID, oldPath: oldPath,
                    newPath: newPath)
                newFiles.removeValue(forKey: newPath)
                session.locallyDeleted.insert(oldPath)
            } else {
                session.locallyDeleted.insert(oldPath)
            }
        }

        // 3. 执行本地原子删除（创建 tombstone）
        let myPeerID = syncManager.p2pNode.peerID?.b58String ?? ""
        for path in session.locallyDeleted {
            syncManager.deleteFileAtomically(path: path, syncID: session.syncID, peerID: myPeerID)
        }
    }

    /// 计划阶段：比较状态并生成操作列表
    func planningPhase(session: inout SyncSession) {
        guard let syncManager = syncManager else { return }

        // 获取本地完整状态（包含 tombstone）
        let localStateStore = syncManager.getFileStateStore(for: session.syncID)
        var localStates: [String: FileState] = [:]

        if let metadata = session.localMetadata {
            for (path, meta) in metadata {
                localStates[path] = .exists(meta)
            }
        }

        for path in localStateStore.getDeletedPaths() {
            if let state = localStateStore.getState(for: path) {
                localStates[path] = state
            }
        }

        // 汇总所有路径
        let allPaths = Set(localStates.keys).union(session.remoteStates.keys)

        for path in allPaths {
            let action = SyncDecisionEngine.decideSyncAction(
                localState: localStates[path],
                remoteState: session.remoteStates[path],
                path: path
            )

            if action != .skip {
                session.actions[path] = action
            }
        }
    }

    /// 执行阶段：根据计划执行上传、下载或删除操作
    func executionPhase(session: inout SyncSession) async {
        guard !session.actions.isEmpty else { return }

        let paths = session.actions.keys.sorted()
        let total = paths.count
        var completed = 0

        // 1. 统计并设置初始待处理计数
        let initialUploads = session.actions.values.filter { $0 == .upload }.count
        let initialDownloads = session.actions.values.filter { $0 == .download }.count

        if initialUploads > 0 {
            await MainActor.run {
                self.syncManager?.addPendingTransfers(initialUploads, direction: .upload)
            }
        }
        if initialDownloads > 0 {
            await MainActor.run {
                self.syncManager?.addPendingTransfers(initialDownloads, direction: .download)
            }
        }

        // 分批处理以控制并发
        let batchSize = 8
        for i in stride(from: 0, to: total, by: batchSize) {
            let batch = Array(paths[i..<min(i + batchSize, total)])

            let currentSession = session
            let folderID = session.folderID

            await withTaskGroup(of: (String, SyncLog.SyncedFileInfo?).self) { group in
                for path in batch {
                    let action = session.actions[path]!
                    group.addTask {
                        let info = await self.executeAction(
                            path: path, action: action, session: currentSession)
                        return (path, info)
                    }
                }

                for await (path, info) in group {
                    completed += 1

                    // 2. 根据操作结果更新待处理计数
                    let action = session.actions[path]!
                    if action == .upload || action == .download {
                        let direction: SyncLog.Direction = (action == .upload ? .upload : .download)
                        await MainActor.run {
                            self.syncManager?.completePendingTransfers(1, direction: direction)
                        }
                    }

                    if let syncedInfo = info {
                        session.filesSynced.append(syncedInfo)
                        session.bytesTransferred += syncedInfo.size
                    }

                    // 更新 UI 进度
                    let progress = 0.2 + (Double(completed) / Double(total) * 0.7)
                    Task { @MainActor in
                        self.syncManager?.updateFolderStatus(
                            folderID, status: .syncing, progress: progress)
                    }
                }
            }
        }
    }

    /// 完成阶段：保存快照、发送通知并记录日志
    func finalizationPhase(session: SyncSession) async {
        guard let syncManager = syncManager else { return }

        // 0. 重置待处理计数（兜底）
        await MainActor.run {
            syncManager.resetPendingTransfers(direction: .bidirectional)
        }

        // 1. 保存当前元数据缓存（用于下次重命名检测）
        if let metadata = session.localMetadata {
            syncManager.lastKnownLocalPaths[session.syncID] = Set(metadata.keys)
            syncManager.lastKnownMetadata[session.syncID] = metadata

            // 2. 原子性保存文件夹快照
            await saveSnapshotAtomically(
                syncID: session.syncID,
                folderID: session.folderID,
                metadata: metadata,
                folderCount: 0,  // 使用占位，由 FolderStatistics 定期更新
                totalSize: session.folder.totalSize ?? 0
            )
        }

        // 3. 更新同步状态
        syncManager.updateFolderStatus(
            session.folderID, status: .synced, message: "Up to date", progress: 1.0)
        syncManager.syncIDManager.updateLastSyncedAt(session.syncID)

        // 4. 记录同步日志
        let direction: SyncLog.Direction =
            session.folder.mode == .uploadOnly
            ? .upload : (session.folder.mode == .downloadOnly ? .download : .bidirectional)

        let log = SyncLog(
            syncID: session.syncID,
            folderID: session.folderID,
            peerID: session.peerID,
            direction: direction,
            bytesTransferred: session.bytesTransferred,
            filesCount: session.filesSynced.count,
            startedAt: session.startedAt,
            completedAt: Date(),
            syncedFiles: session.filesSynced
        )
        try? StorageManager.shared.addSyncLog(log)

        AppLogger.syncPrint(
            "[SyncEngine] ✅ 同步完成: \(session.syncID), 传输: \(session.bytesTransferred) bytes, 文件: \(session.filesSynced.count)"
        )

        // 5. 触发统计更新（异步）
        if let folderStatistics = folderStatistics {
            Task {
                folderStatistics.refreshFileCount(for: session.folder)
            }
        }
    }
}

enum SyncError: Error {
    case remoteFolderMissing
    case invalidResponse
    case connectionFailed
}
