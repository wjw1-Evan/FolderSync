import Foundation

/// 同步引擎
/// 负责核心的同步逻辑，包括对等点注册、同步协调和文件同步执行
@MainActor
class SyncEngine {
    weak var syncManager: SyncManager?
    weak var fileTransfer: FileTransfer?
    weak var folderStatistics: FolderStatistics?

    private let chunkSyncThreshold: Int64 = 1 * 1024 * 1024  // 1MB，超过此大小的文件使用块级增量同步
    private let maxConcurrentTransfers = 3  // 最大并发传输数（上传/下载）

    init(syncManager: SyncManager, fileTransfer: FileTransfer, folderStatistics: FolderStatistics) {
        self.syncManager = syncManager
        self.fileTransfer = fileTransfer
        self.folderStatistics = folderStatistics
    }

    /// 与指定对等点同步指定文件夹
    func syncWithPeer(peer: PeerID, folder: SyncFolder) {
        guard let syncManager = syncManager else { return }

        let peerID = peer.b58String
        let syncKey = "\(folder.syncID):\(peerID)"

        Task { @MainActor in
            // 检查设备是否在线，离线设备不进行同步
            if !syncManager.peerManager.isOnline(peerID) {
                print("[SyncEngine] ⏭️ [syncWithPeer] 设备已离线，跳过同步: \(peerID.prefix(12))...")
                return
            }

            // 检查是否正在同步
            if syncManager.syncInProgress.contains(syncKey) {
                return
            }

            // 确保对等点已注册（带重试机制）
            let registrationResult = await ensurePeerRegistered(peer: peer, peerID: peerID)

            guard registrationResult.success else {
                print("[SyncEngine] ❌ [syncWithPeer] 对等点注册失败，跳过同步: \(peerID.prefix(12))...")
                syncManager.updateFolderStatus(
                    folder.id, status: .error, message: "对等点注册失败", progress: 0.0)
                return
            }

            // 标记为正在同步
            syncManager.syncInProgress.insert(syncKey)

            // 使用 defer 确保在函数返回时移除同步标记
            defer {
                syncManager.syncInProgress.remove(syncKey)
            }

            // 执行同步（此时对等点已确保注册成功）
            await performSync(peer: peer, folder: folder, peerID: peerID)
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

        print("[SyncEngine] ⚠️ [ensurePeerRegistered] 对等点未注册，尝试注册: \(peerID.prefix(12))...")

        // 获取对等点地址
        let peerAddresses = syncManager.p2pNode.peerManager.getAddresses(for: peerID)

        if peerAddresses.isEmpty {
            print("[SyncEngine] ❌ [ensurePeerRegistered] 对等点无可用地址: \(peerID.prefix(12))...")
            return (false, false)
        }

        // 尝试注册
        let registered = syncManager.p2pNode.registrationService.registerPeer(
            peerID: peer, addresses: peerAddresses)

        if !registered {
            print("[SyncEngine] ❌ [ensurePeerRegistered] 对等点注册失败: \(peerID.prefix(12))...")
            return (false, false)
        }

        print("[SyncEngine] ✅ [ensurePeerRegistered] 对等点注册成功，等待注册完成: \(peerID.prefix(12))...")

        // 等待注册完成（使用重试机制，最多等待 2 秒）
        let maxWaitTime: TimeInterval = 2.0
        let checkInterval: TimeInterval = 0.2
        let maxRetries = Int(maxWaitTime / checkInterval)

        for attempt in 1...maxRetries {
            try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))

            if syncManager.p2pNode.registrationService.isRegistered(peerID) {
                print(
                    "[SyncEngine] ✅ [ensurePeerRegistered] 对等点注册确认成功: \(peerID.prefix(12))... (尝试 \(attempt)/\(maxRetries))"
                )
                return (true, true)
            }
        }

        // 即使等待超时，如果注册状态显示正在注册中，也认为成功（可能是异步延迟）
        let registrationState = syncManager.p2pNode.registrationService.getRegistrationState(peerID)
        if case .registering = registrationState {
            print("[SyncEngine] ⚠️ [ensurePeerRegistered] 对等点正在注册中，继续尝试: \(peerID.prefix(12))...")
            return (true, true)
        }

        print("[SyncEngine] ⚠️ [ensurePeerRegistered] 对等点注册等待超时，但继续尝试: \(peerID.prefix(12))...")
        return (true, true)  // 即使超时也继续，让同步过程处理
    }

    /// 执行同步操作
    private func performSync(peer: PeerID, folder: SyncFolder, peerID: String) async {
        guard let syncManager = syncManager,
            let folderStatistics = folderStatistics
        else {
            return
        }

        // fileTransfer 在异步任务中使用，只需要检查是否存在
        guard fileTransfer != nil else {
            return
        }

        let startedAt = Date()
        let folderID = folder.id
        let syncID = folder.syncID

        // 重要：从 syncManager 中获取最新的 folder 对象，避免使用过时的统计值
        let currentFolder = await MainActor.run {
            return syncManager.folders.first(where: { $0.id == folderID })
        }

        guard let currentFolder = currentFolder else {
            print("[SyncEngine] ⚠️ [performSync] 文件夹已不存在: \(folderID)")
            // 文件夹不存在，无法记录日志
            return
        }

        do {
            guard !peerID.isEmpty else {
                print("[SyncEngine] ❌ [performSync] PeerID 无效")
                syncManager.updateFolderStatus(
                    currentFolder.id, status: .error, message: "PeerID 无效")
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
                print("[SyncEngine] ⚠️ [performSync] 警告: 对等点没有可用地址")
                syncManager.updateFolderStatus(
                    currentFolder.id, status: .error, message: "对等点无可用地址", progress: 0.0)
                // 记录错误日志
                let log = SyncLog(
                    syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional,
                    bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(),
                    errorMessage: "对等点无可用地址")
                try? StorageManager.shared.addSyncLog(log)
                return
            }

            // 尝试使用原生网络服务
            let rootRes: SyncResponse
            do {
                let addressStrings = peerAddresses.map { $0.description }

                guard let address = AddressConverter.extractFirstAddress(from: addressStrings)
                else {
                    let errorMsg = "无法从地址中提取 IP:Port（地址数: \(addressStrings.count)）"
                    print("[SyncEngine] ❌ [performSync] \(errorMsg)")
                    throw NSError(
                        domain: "SyncEngine", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: errorMsg])
                }

                // 验证提取的地址
                let addressComponents = address.split(separator: ":")
                guard addressComponents.count == 2,
                    let extractedIP = String(addressComponents[0]).removingPercentEncoding,
                    let extractedPort = UInt16(String(addressComponents[1])),
                    extractedPort > 0,
                    extractedPort <= 65535
                else {
                    print("[SyncEngine] ❌ [performSync] 地址格式验证失败: \(address)")
                    throw NSError(
                        domain: "SyncEngine", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "地址格式无效: \(address)"])
                }

                // 验证IP地址格式
                if extractedIP.isEmpty || extractedIP == "0.0.0.0" {
                    print("[SyncEngine] ❌ [performSync] IP地址无效: '\(extractedIP)'")
                    throw NSError(
                        domain: "SyncEngine", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "IP地址无效: \(extractedIP)"])
                }

                // 使用原生网络服务发送请求
                rootRes =
                    try await syncManager.p2pNode.nativeNetwork.sendRequest(
                        .getMST(syncID: syncID),
                        to: address,
                        timeout: 10.0,
                        maxRetries: 2
                    ) as SyncResponse
            } catch {
                let errorString = String(describing: error)
                print("[SyncEngine] ❌ [performSync] 原生 TCP 请求失败: \(errorString)")

                // 检查是否是超时或连接失败错误，如果是，将设备标记为离线
                let isTimeoutOrConnectionError =
                    errorString.contains("TimedOut") || errorString.contains("timeout")
                    || errorString.contains("请求超时") || errorString.contains("connection")
                    || errorString.contains("Connection") || errorString.contains("unreachable")

                if isTimeoutOrConnectionError {
                    // 将设备标记为离线，避免重复尝试连接
                    await MainActor.run {
                        syncManager.peerManager.updateOnlineStatus(peerID, isOnline: false)
                    }
                    print("[SyncEngine] ⚠️ [performSync] 对等点连接失败，已标记为离线: \(peerID.prefix(12))...")
                }

                syncManager.updateFolderStatus(
                    currentFolder.id, status: .error, message: "对等点连接失败，等待下次发现", progress: 0.0)
                // 记录错误日志
                let log = SyncLog(
                    syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional,
                    bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(),
                    errorMessage: "对等点连接失败: \(error.localizedDescription)")
                try? StorageManager.shared.addSyncLog(log)
                return
            }

            if case .error = rootRes {
                // Remote doesn't have this folder
                syncManager.removeFolderPeer(syncID, peerID: peerID)
                return
            }

            // Peer confirmed to have this folder
            syncManager.addFolderPeer(syncID, peerID: peerID)
            syncManager.syncIDManager.updateLastSyncedAt(syncID)
            syncManager.peerManager.updateOnlineStatus(peerID, isOnline: true)
            syncManager.updateDeviceCounts()

            guard case .mstRoot(_, let remoteHash) = rootRes else {
                print("[SyncEngine] ❌ [performSync] rootRes 不是 mstRoot 类型")
                // 记录错误日志
                let log = SyncLog(
                    syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional,
                    bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(),
                    errorMessage: "获取远程 MST 根失败：响应类型错误")
                try? StorageManager.shared.addSyncLog(log)
                return
            }

            // 重要：使用最新的 folder 对象计算状态，而不是传入的旧对象
            // calculateFullState 已经排除了冲突文件，所以 localMetadata 不包含冲突文件
            let (localMST, localMetadataRaw, _, _) = await folderStatistics.calculateFullState(
                for: currentFolder)
            
            // 再次过滤冲突文件（双重保险，确保冲突文件不会被同步）
            let localMetadata = ConflictFileFilter.filterConflictFiles(localMetadataRaw)

            let currentPaths = Set(localMetadata.keys)
            let lastKnown = syncManager.lastKnownLocalPaths[syncID] ?? []
            let lastKnownMeta = syncManager.lastKnownMetadata[syncID] ?? [:]

            // 如果是第一次同步（lastKnown 为空），初始化 lastKnown 为当前路径，不检测删除
            // 这样可以避免第一次同步时误判删除
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
            if !isFirstSync {
                for (oldPath, oldMeta) in disappearedFiles {
                    // 查找具有相同哈希值的新文件
                    if let (newPath, _) = newFiles.first(where: { $0.value.hash == oldMeta.hash }) {
                        // 找到匹配！这是重命名操作
                        renamedFiles[oldPath] = newPath
                        newFiles.removeValue(forKey: newPath)  // 从新文件列表中移除，因为它是重命名
                        print("[SyncEngine] 🔄 检测到文件重命名: \(oldPath) -> \(newPath)")
                    } else {
                        // 没有找到匹配，这是真正的删除
                        locallyDeleted.insert(oldPath)
                    }
                }
            }

            // 处理重命名：迁移 Vector Clock 路径映射（使用 VectorClockManager）
            for (oldPath, newPath) in renamedFiles {
                VectorClockManager.migrateVectorClock(
                    syncID: syncID,
                    oldPath: oldPath,
                    newPath: newPath
                )
            }

            // 更新 deletedPaths（只包含真正的删除，不包括重命名）
            if !locallyDeleted.isEmpty {
                var dp = syncManager.deletedPaths(for: syncID)
                dp.formUnion(locallyDeleted)
                syncManager.updateDeletedPaths(dp, for: syncID)
            }

            let mode = currentFolder.mode

            if localMST.rootHash == remoteHash && locallyDeleted.isEmpty {
                // 本地和远程已经同步
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

            // 2. Roots differ, get remote file list
            syncManager.updateFolderStatus(
                currentFolder.id, status: .syncing, message: "正在获取远程文件列表...", progress: 0.1)

            let filesRes: SyncResponse
            do {
                filesRes = try await syncManager.sendSyncRequest(
                    .getFiles(syncID: syncID),
                    to: peer,
                    peerID: peerID,
                    timeout: 90.0,
                    maxRetries: 3,
                    folder: currentFolder
                )
            } catch {
                print("[SyncEngine] ❌ [performSync] 获取远程文件列表失败: \(error)")
                syncManager.updateFolderStatus(
                    currentFolder.id, status: .error,
                    message: "获取远程文件列表失败: \(error.localizedDescription)")
                // 记录错误日志
                let log = SyncLog(
                    syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional,
                    bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(),
                    errorMessage: "获取远程文件列表失败: \(error.localizedDescription)")
                try? StorageManager.shared.addSyncLog(log)
                return
            }

            guard case .files(_, let remoteEntriesRaw) = filesRes else {
                print("[SyncEngine] ❌ [performSync] filesRes 不是 files 类型")
                // 记录错误日志
                let log = SyncLog(
                    syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional,
                    bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(),
                    errorMessage: "获取远程文件列表失败：响应类型错误")
                try? StorageManager.shared.addSyncLog(log)
                return
            }
            
            // 过滤掉冲突文件（冲突文件不应该被同步，避免无限循环）
            let remoteEntries = ConflictFileFilter.filterConflictFiles(remoteEntriesRaw)

            let myPeerID = await MainActor.run { syncManager.p2pNode.peerID ?? "" }
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
            func downloadAction(remote: FileMetadata, local: FileMetadata?, path: String) -> DownloadAction {
                let localVC = local?.vectorClock
                let remoteVC = remote.vectorClock
                let localHash = local?.hash ?? ""
                let remoteHash = remote.hash
                
                let decision = VectorClockManager.decideSyncAction(
                    localVC: localVC,
                    remoteVC: remoteVC,
                    localHash: localHash,
                    remoteHash: remoteHash,
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
                        print("[SyncEngine] ⚠️ [downloadAction] 无法确定同步方向，保存为冲突文件: 路径=\(path)")
                    }
                    return .conflict
                case .conflict:
                    print("[SyncEngine] ⚠️ [downloadAction] Vector Clock 并发冲突，保存为冲突文件: 路径=\(path)")
                    return .conflict
                }
            }

            /// 决定是否上传（使用 VectorClockManager 统一决策逻辑）
            /// 
            /// 注意：此函数已被重构，冲突检测现在在上层统一处理。
            /// 此函数保留用于 FileTransfer 等需要简单布尔判断的场景。
            nonisolated func shouldUpload(local: FileMetadata, remote: FileMetadata?, path: String) -> Bool {
                let localVC = local.vectorClock
                let remoteVC = remote?.vectorClock
                let localHash = local.hash
                let remoteHash = remote?.hash ?? ""
                
                let decision = VectorClockManager.decideSyncAction(
                    localVC: localVC,
                    remoteVC: remoteVC,
                    localHash: localHash,
                    remoteHash: remoteHash,
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

            // 清理已确认删除的文件（远程也没有了）
            // 注意：如果文件在远程不存在，说明删除已经完成，从 deletedSet 中移除
            let confirmed = deletedSet.filter { !remoteEntries.keys.contains($0) }
            for p in confirmed {
                deletedSet.remove(p)
                // 同时从 locallyDeleted 中移除（如果存在），因为远程已经确认删除
                locallyDeleted.remove(p)
            }
            if deletedSet.isEmpty {
                syncManager.removeDeletedPaths(for: syncID)
            } else {
                syncManager.updateDeletedPaths(deletedSet, for: syncID)
            }

            // 3. Download phase
            var changedFilesSet: Set<String> = []
            var conflictFilesSet: Set<String> = []
            var changedFiles: [(String, FileMetadata)] = []
            var conflictFiles: [(String, FileMetadata)] = []

            if mode == .twoWay || mode == .downloadOnly {
                for (path, remoteMeta) in remoteEntries {
                    // 重要：排除冲突文件（冲突文件不应该被同步，避免无限循环）
                    if ConflictFileFilter.isConflictFile(path) {
                        continue
                    }
                    
                    // 重要：如果文件在本地被删除（locallyDeleted）或已标记删除（deletedSet），不应该下载
                    // 同时检查文件是否在本地存在（如果不存在且不在 lastKnown 中，可能是第一次同步，应该下载）
                    if locallyDeleted.contains(path) || deletedSet.contains(path) {
                        continue
                    }
                    // 额外检查：如果文件在本地不存在，且不在 lastKnown 中（第一次同步），应该下载
                    // 但如果文件在本地不存在，且在 lastKnown 中（已删除），不应该下载
                    let fileURL = currentFolder.localPath.appendingPathComponent(path)
                    if !fileManager.fileExists(atPath: fileURL.path) {
                        // 文件不存在，检查是否在 lastKnown 中
                        if lastKnown.contains(path) {
                            // 文件在 lastKnown 中但不存在，说明被删除了，不应该下载
                            continue
                        }
                        // 文件不在 lastKnown 中，可能是第一次同步，应该下载
                    }
                    if changedFilesSet.contains(path) || conflictFilesSet.contains(path) {
                        continue
                    }
                    switch downloadAction(remote: remoteMeta, local: localMetadata[path], path: path) {
                    case .skip: break
                    case .overwrite:
                        changedFilesSet.insert(path)
                        changedFiles.append((path, remoteMeta))
                    case .conflict:
                        conflictFilesSet.insert(path)
                        conflictFiles.append((path, remoteMeta))
                    }
                }
            }
            totalOps += changedFiles.count + conflictFiles.count

            // 4. Upload phase - 检测上传冲突
            var filesToUploadSet: Set<String> = []
            var filesToUpload: [(String, FileMetadata)] = []
            var uploadConflictFiles: [(String, FileMetadata)] = []  // 上传时的冲突文件（需要先保存远程版本）

            if mode == .twoWay || mode == .uploadOnly {
                for (path, localMeta) in localMetadata {
                    // 重要：排除冲突文件（冲突文件不应该被同步，避免无限循环）
                    if ConflictFileFilter.isConflictFile(path) {
                        continue
                    }
                    
                    // 跳过已删除的文件
                    if locallyDeleted.contains(path) {
                        continue
                    }
                    // 跳过重命名的旧路径（旧路径会在删除阶段处理，新路径会正常上传）
                    if renamedFiles.keys.contains(path) {
                        // 这是重命名的旧路径，跳过（新路径会正常上传）
                        continue
                    }
                    if filesToUploadSet.contains(path) {
                        continue
                    }

                    // 统一使用 VectorClockManager 检测冲突（包括并发冲突和 equal 但哈希不同的情况）
                    let remoteMeta = remoteEntries[path]
                    let decision = VectorClockManager.decideSyncAction(
                        localVC: localMeta.vectorClock,
                        remoteVC: remoteMeta?.vectorClock,
                        localHash: localMeta.hash,
                        remoteHash: remoteMeta?.hash ?? "",
                        direction: .upload
                    )
                    
                    switch decision {
                    case .skip, .overwriteLocal:
                        // 不需要上传
                        break
                    case .overwriteRemote:
                        // 需要上传覆盖远程
                        filesToUploadSet.insert(path)
                        filesToUpload.append((path, localMeta))
                    case .conflict:
                        // 冲突：需要先保存远程版本为冲突文件，然后再上传本地版本
                        if let remoteMeta = remoteMeta {
                            uploadConflictFiles.append((path, remoteMeta))
                            filesToUploadSet.insert(path)
                            filesToUpload.append((path, localMeta))
                        } else {
                            // 没有远程元数据，但检测到冲突（可能是 equal 但哈希不同），直接上传
                            print("[SyncEngine] ⚠️ [upload] 检测到冲突但无远程元数据，直接上传: 路径=\(path)")
                            filesToUploadSet.insert(path)
                            filesToUpload.append((path, localMeta))
                        }
                    case .uncertain:
                        // 无法确定：采用本地优先策略
                        print("[SyncEngine] ⚠️ [upload] 无法确定同步方向，采用本地优先上传策略: 路径=\(path)")
                        filesToUploadSet.insert(path)
                        filesToUpload.append((path, localMeta))
                    }
                }
            }
            totalOps += filesToUpload.count + uploadConflictFiles.count

            // 处理删除和重命名：重命名需要先在远程删除旧路径，然后上传新路径
            var toDelete = (mode == .twoWay || mode == .uploadOnly) ? locallyDeleted : []
            // 重命名操作：需要在远程删除旧路径
            if mode == .twoWay || mode == .uploadOnly {
                for oldPath in renamedFiles.keys {
                    toDelete.insert(oldPath)
                }
            }
            if !toDelete.isEmpty {
                totalOps += toDelete.count
            }

            if totalOps > 0 {
                syncManager.updateFolderStatus(
                    currentFolder.id, status: .syncing, message: "准备同步 \(totalOps) 个操作...",
                    progress: 0.2)
            }

            // 重要：先执行删除操作，确保远程删除后再进行下载，避免下载已删除的文件
            if !toDelete.isEmpty {
                syncManager.updateFolderStatus(
                    currentFolder.id, status: .syncing, message: "正在删除 \(toDelete.count) 个文件...",
                    progress: Double(completedOps) / Double(max(totalOps, 1)))

                let delRes: SyncResponse = try await syncManager.sendSyncRequest(
                    .deleteFiles(syncID: syncID, paths: Array(toDelete)),
                    to: peer,
                    peerID: peerID,
                    timeout: 90.0,
                    maxRetries: 3,
                    folder: currentFolder
                )

                if case .deleteAck = delRes {
                    // 删除成功后，从 deletedSet 中移除这些文件，避免后续逻辑重复处理
                    for rel in toDelete {
                        deletedSet.remove(rel)
                        // 同时从 locallyDeleted 中移除，因为删除已经完成
                        locallyDeleted.remove(rel)

                        let fileURL = currentFolder.localPath.appendingPathComponent(rel)
                        let fileName = (rel as NSString).lastPathComponent
                        let pathDir = (rel as NSString).deletingLastPathComponent
                        let folderName =
                            pathDir.isEmpty ? nil : (pathDir as NSString).lastPathComponent

                        var fileSize: Int64 = 0
                        if fileManager.fileExists(atPath: fileURL.path),
                            let attributes = try? fileManager.attributesOfItem(
                                atPath: fileURL.path),
                            let size = attributes[FileAttributeKey.size] as? Int64
                        {
                            fileSize = size
                        }

                        if fileManager.fileExists(atPath: fileURL.path) {
                            try? fileManager.removeItem(at: fileURL)
                        }

                        VectorClockManager.deleteVectorClock(syncID: syncID, path: rel)

                        syncedFiles.append(
                            SyncLog.SyncedFileInfo(
                                path: rel,
                                fileName: fileName,
                                folderName: folderName,
                                size: fileSize,
                                operation: .delete
                            ))
                    }
                    completedOps += toDelete.count

                    // 更新 deletedPaths，移除已成功删除的文件
                    if deletedSet.isEmpty {
                        syncManager.removeDeletedPaths(for: syncID)
                    } else {
                        syncManager.updateDeletedPaths(deletedSet, for: syncID)
                    }
                } else {
                    // 删除失败，记录错误但不阻止后续操作
                    print("[SyncEngine] ⚠️ 删除操作失败，响应: \(delRes)")
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

            // 5. Download changed files - 并行下载（删除操作已执行，不会下载已删除的文件）
            // 重要：在下载之前，再次检查 deletedSet 和 locallyDeleted，确保已删除的文件不会被下载
            var totalDownloadBytes: Int64 = 0
            var totalUploadBytes: Int64 = 0

            // 过滤掉已删除的文件（删除操作执行后，这些文件应该已经从 deletedSet 中移除，但为了安全再次检查）
            let filesToDownload = changedFiles.filter { path, _ in
                !locallyDeleted.contains(path) && !deletedSet.contains(path)
            }

            let transferOpsCount =
                filesToDownload.count + conflictFiles.count
                + uploadConflictFiles.count + filesToUpload.count
            if transferOpsCount > 0 {
                registerPendingTransfers(transferOpsCount)
            }
            defer { cleanupPendingTransfers() }

            await withTaskGroup(of: (Int64, SyncLog.SyncedFileInfo)?.self) { group in
                var activeDownloads = 0

                for (path, remoteMeta) in filesToDownload {
                    if activeDownloads >= maxConcurrentTransfers {
                        if let result = await group.next() {
                            markTransferCompleted()
                            if let (bytes, fileInfo) = result {
                                totalDownloadBytes += bytes
                                syncedFiles.append(fileInfo)
                                completedOps += 1

                                await MainActor.run {
                                    syncManager.addDownloadBytes(bytes)
                                }
                                await MainActor.run {
                                    syncManager.updateFolderStatus(
                                        currentFolder.id, status: .syncing,
                                        message: "下载完成: \(completedOps)/\(totalOps)",
                                        progress: Double(completedOps)
                                            / Double(max(totalOps, 1)))
                                }
                            }
                        } else {
                            markTransferCompleted()
                        }
                        activeDownloads -= 1
                    }

                    activeDownloads += 1

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
                            let localURL = latestFolder.localPath.appendingPathComponent(path)
                            let fileManager = FileManager.default
                            var fileSize: Int64 = 0

                            if fileManager.fileExists(atPath: localURL.path),
                                let attributes = try? fileManager.attributesOfItem(
                                    atPath: localURL.path),
                                let size = attributes[.size] as? Int64
                            {
                                fileSize = size
                            }

                            if fileSize >= self.chunkSyncThreshold {
                                return try await fileTransfer.downloadFileWithChunks(
                                    path: path,
                                    remoteMeta: remoteMeta,
                                    folder: latestFolder,
                                    peer: peer,
                                    peerID: peerID,
                                    localMetadata: localMetadata
                                )
                            } else {
                                return try await fileTransfer.downloadFileFull(
                                    path: path,
                                    remoteMeta: remoteMeta,
                                    folder: latestFolder,
                                    peer: peer,
                                    peerID: peerID,
                                    localMetadata: localMetadata
                                )
                            }
                        } catch {
                            print("[SyncEngine] ❌ 下载文件失败: \(path) - \(error.localizedDescription)")
                            return nil
                        }
                    }
                }

                for await result in group {
                    markTransferCompleted()
                    if let (bytes, fileInfo) = result {
                        totalDownloadBytes += bytes
                        syncedFiles.append(fileInfo)
                        completedOps += 1

                        await MainActor.run {
                            syncManager.addDownloadBytes(bytes)
                        }
                        syncManager.updateFolderStatus(
                            currentFolder.id, status: .syncing,
                            message: "下载完成: \(completedOps)/\(totalOps)",
                            progress: Double(completedOps) / Double(max(totalOps, 1)))
                    }
                }
            }

            // 5b. Download conflict files
            await withTaskGroup(of: (Int64, SyncLog.SyncedFileInfo)?.self) { group in
                for (path, remoteMeta) in conflictFiles {
                    let fileName = (path as NSString).lastPathComponent

                    group.addTask { [weak self] in
                        guard let self = self else { return nil }

                        let syncManager = await MainActor.run { self.syncManager }
                        guard let syncManager = syncManager else { return nil }

                        // 获取最新的 folder 对象
                        let latestFolder = await MainActor.run {
                            return syncManager.folders.first(where: { $0.id == folderID })
                        }
                        guard let latestFolder = latestFolder else { return nil }

                        do {
                            let dataRes: SyncResponse = try await syncManager.sendSyncRequest(
                                .getFileData(syncID: syncID, path: path),
                                to: peer,
                                peerID: peerID,
                                timeout: 180.0,
                                maxRetries: 3,
                                folder: latestFolder
                            )

                            guard case .fileData(_, _, let data) = dataRes else {
                                return nil
                            }

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
                            let fileManager = FileManager.default

                            if !fileManager.fileExists(atPath: parent.path) {
                                try fileManager.createDirectory(
                                    at: parent, withIntermediateDirectories: true)
                            }

                            guard fileManager.isWritableFile(atPath: parent.path) else {
                                throw NSError(
                                    domain: "SyncEngine", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "没有写入权限: \(parent.path)"])
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
                                    path: path,
                                    fileName: fileName,
                                    folderName: folderName,
                                    size: Int64(data.count),
                                    operation: .conflict
                                )
                            )
                        } catch {
                            print(
                                "[SyncEngine] ❌ 下载冲突文件失败: \(path) - \(error.localizedDescription)")
                            return nil
                        }
                    }
                }

                for await result in group {
                    markTransferCompleted()
                    if let (bytes, fileInfo) = result {
                        totalDownloadBytes += bytes
                        syncedFiles.append(fileInfo)
                        completedOps += 1

                        await MainActor.run {
                            syncManager.addDownloadBytes(bytes)
                        }
                        syncManager.updateFolderStatus(
                            currentFolder.id, status: .syncing,
                            message: "冲突处理完成: \(completedOps)/\(totalOps)",
                            progress: Double(completedOps) / Double(max(totalOps, 1)))
                    }
                }
            }

            // 5c. 处理上传冲突：先下载远程版本保存为冲突文件
            await withTaskGroup(of: (Int64, SyncLog.SyncedFileInfo)?.self) { group in
                for (path, remoteMeta) in uploadConflictFiles {
                    let fileName = (path as NSString).lastPathComponent

                    group.addTask { [weak self] in
                        guard let self = self else { return nil }

                        let syncManager = await MainActor.run { self.syncManager }
                        guard let syncManager = syncManager else { return nil }

                        // 获取最新的 folder 对象
                        let latestFolder = await MainActor.run {
                            return syncManager.folders.first(where: { $0.id == folderID })
                        }
                        guard let latestFolder = latestFolder else { return nil }

                        do {
                            // 下载远程版本保存为冲突文件
                            let dataRes: SyncResponse = try await syncManager.sendSyncRequest(
                                .getFileData(syncID: syncID, path: path),
                                to: peer,
                                peerID: peerID,
                                timeout: 180.0,
                                maxRetries: 3,
                                folder: latestFolder
                            )

                            guard case .fileData(_, _, let data) = dataRes else {
                                return nil
                            }

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
                            let fileManager = FileManager.default

                            if !fileManager.fileExists(atPath: parent.path) {
                                try fileManager.createDirectory(
                                    at: parent, withIntermediateDirectories: true)
                            }

                            guard fileManager.isWritableFile(atPath: parent.path) else {
                                throw NSError(
                                    domain: "SyncEngine", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "没有写入权限: \(parent.path)"])
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
                                    path: path,
                                    fileName: fileName,
                                    folderName: folderName,
                                    size: Int64(data.count),
                                    operation: .conflict
                                )
                            )
                        } catch {
                            print(
                                "[SyncEngine] ⚠️ 保存上传冲突文件失败: \(path) - \(error.localizedDescription)"
                            )
                            return nil
                        }
                    }
                }

                for await result in group {
                    markTransferCompleted()
                    if let (bytes, fileInfo) = result {
                        totalDownloadBytes += bytes
                        syncedFiles.append(fileInfo)
                        completedOps += 1

                        await MainActor.run {
                            syncManager.addDownloadBytes(bytes)
                        }
                        syncManager.updateFolderStatus(
                            currentFolder.id, status: .syncing,
                            message: "冲突处理完成: \(completedOps)/\(totalOps)",
                            progress: Double(completedOps) / Double(max(totalOps, 1)))
                    }
                }
            }

            // 6. Upload files to remote - 并行上传
            await withTaskGroup(of: (Int64, SyncLog.SyncedFileInfo)?.self) { group in
                var activeUploads = 0

                for (path, localMeta) in filesToUpload {
                    if activeUploads >= maxConcurrentTransfers {
                        if let result = await group.next() {
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
                        } else {
                            markTransferCompleted()
                        }
                        activeUploads -= 1
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
                            let fileManager = FileManager.default

                            guard fileManager.fileExists(atPath: fileURL.path) else {
                                print("[SyncEngine] ⚠️ 文件不存在（跳过上传）: \(fileURL.path)")
                                return nil
                            }

                            guard fileManager.isReadableFile(atPath: fileURL.path) else {
                                print("[SyncEngine] ⚠️ 文件无读取权限（跳过上传）: \(fileURL.path)")
                                return nil
                            }

                            let fileAttributes = try fileManager.attributesOfItem(
                                atPath: fileURL.path)
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
                            print("[SyncEngine] ❌ 上传文件失败: \(path) - \(error.localizedDescription)")
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
                            print("[SyncEngine] ⚠️ 无法保存文件夹统计信息更新: \(error)")
                        }
                    }
                }
            }

            let totalBytes = totalDownloadBytes + totalUploadBytes

            syncManager.updateFolderStatus(
                currentFolder.id, status: .synced, message: "同步完成", progress: 1.0)
            syncManager.syncIDManager.updateLastSyncedAt(syncID)
            syncManager.peerManager.updateOnlineStatus(peerID, isOnline: true)
            syncManager.updateDeviceCounts()
            syncManager.syncCooldown[syncID] = Date()
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
            print("[SyncEngine] ❌ [performSync] 同步失败!")
            print("[SyncEngine]   文件夹: \(syncID)")
            print("[SyncEngine]   对等点: \(peerID.prefix(12))...")
            print("[SyncEngine]   耗时: \(String(format: "%.2f", duration)) 秒")
            print("[SyncEngine]   错误: \(error)")

            syncManager.removeFolderPeer(syncID, peerID: peerID)
            let errorMessage =
                error.localizedDescription.isEmpty ? "同步失败: \(error)" : error.localizedDescription
            syncManager.updateFolderStatus(currentFolder.id, status: .error, message: errorMessage)

            let log = SyncLog(
                syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional,
                bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: nil,
                errorMessage: error.localizedDescription)
            do {
                try StorageManager.shared.addSyncLog(log)
            } catch {
                print("[SyncEngine] ⚠️ 无法保存同步日志: \(error)")
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
                   let size = attrs[.size] as? Int64 {
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
                print("[SyncEngine] ✅ 已原子保存文件夹快照: \(syncID)")
            } catch {
                print("[SyncEngine] ⚠️ 保存文件夹快照失败: \(error)")
            }
        }
    }
}
