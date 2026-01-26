import Foundation

/// 同步引擎
/// 负责核心的同步逻辑，包括对等点注册、同步协调和文件同步执行
@MainActor
class SyncEngine {
    weak var syncManager: SyncManager?
    weak var fileTransfer: FileTransfer?
    weak var folderStatistics: FolderStatistics?
    
    private let chunkSyncThreshold: Int64 = 1 * 1024 * 1024 // 1MB，超过此大小的文件使用块级增量同步
    private let maxConcurrentTransfers = 3 // 最大并发传输数（上传/下载）
    
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
                syncManager.updateFolderStatus(folder.id, status: .error, message: "对等点注册失败", progress: 0.0)
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
    private func ensurePeerRegistered(peer: PeerID, peerID: String) async -> (success: Bool, isNewlyRegistered: Bool) {
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
        let registered = syncManager.p2pNode.registrationService.registerPeer(peerID: peer, addresses: peerAddresses)
        
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
                print("[SyncEngine] ✅ [ensurePeerRegistered] 对等点注册确认成功: \(peerID.prefix(12))... (尝试 \(attempt)/\(maxRetries))")
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
        return (true, true) // 即使超时也继续，让同步过程处理
    }
    
    /// 执行同步操作
    private func performSync(peer: PeerID, folder: SyncFolder, peerID: String) async {
        guard let syncManager = syncManager,
              let fileTransfer = fileTransfer,
              let folderStatistics = folderStatistics else {
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
                syncManager.updateFolderStatus(currentFolder.id, status: .error, message: "PeerID 无效")
                // 记录错误日志
                let log = SyncLog(syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional, bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(), errorMessage: "PeerID 无效")
                try? StorageManager.shared.addSyncLog(log)
                return
            }
            
            syncManager.updateFolderStatus(currentFolder.id, status: .syncing, message: "正在连接到 \(peerID.prefix(12))...", progress: 0.0)
            
            // 获取远程 MST 根
            let peerAddresses = syncManager.p2pNode.peerManager.getAddresses(for: peer.b58String)
            if peerAddresses.isEmpty {
                print("[SyncEngine] ⚠️ [performSync] 警告: 对等点没有可用地址")
                syncManager.updateFolderStatus(currentFolder.id, status: .error, message: "对等点无可用地址", progress: 0.0)
                // 记录错误日志
                let log = SyncLog(syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional, bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(), errorMessage: "对等点无可用地址")
                try? StorageManager.shared.addSyncLog(log)
                return
            }
            
            // 尝试使用原生网络服务
            let rootRes: SyncResponse
            do {
                let addressStrings = peerAddresses.map { $0.description }
                
                guard let address = AddressConverter.extractFirstAddress(from: addressStrings) else {
                    let errorMsg = "无法从地址中提取 IP:Port（地址数: \(addressStrings.count)）"
                    print("[SyncEngine] ❌ [performSync] \(errorMsg)")
                    throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
                }
                
                // 验证提取的地址
                let addressComponents = address.split(separator: ":")
                guard addressComponents.count == 2,
                      let extractedIP = String(addressComponents[0]).removingPercentEncoding,
                      let extractedPort = UInt16(String(addressComponents[1])),
                      extractedPort > 0,
                      extractedPort <= 65535 else {
                    print("[SyncEngine] ❌ [performSync] 地址格式验证失败: \(address)")
                    throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "地址格式无效: \(address)"])
                }
                
                // 验证IP地址格式
                if extractedIP.isEmpty || extractedIP == "0.0.0.0" {
                    print("[SyncEngine] ❌ [performSync] IP地址无效: '\(extractedIP)'")
                    throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "IP地址无效: \(extractedIP)"])
                }
                
                // 使用原生网络服务发送请求
                rootRes = try await syncManager.p2pNode.nativeNetwork.sendRequest(
                    .getMST(syncID: syncID),
                    to: address,
                    timeout: 10.0,
                    maxRetries: 2
                ) as SyncResponse
            } catch {
                let errorString = String(describing: error)
                print("[SyncEngine] ❌ [performSync] 原生 TCP 请求失败: \(errorString)")
                syncManager.updateFolderStatus(currentFolder.id, status: .error, message: "对等点连接失败，等待下次发现", progress: 0.0)
                // 记录错误日志
                let log = SyncLog(syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional, bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(), errorMessage: "对等点连接失败: \(error.localizedDescription)")
                try? StorageManager.shared.addSyncLog(log)
                return
            }
            
            if case .error = rootRes {
                // Remote doesn't have this folder
                syncManager.removeFolderPeer(syncID, peerID: peerID)
                // 记录信息日志（远程没有此文件夹）
                let log = SyncLog(syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional, bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(), errorMessage: "远程对等点没有此同步文件夹")
                try? StorageManager.shared.addSyncLog(log)
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
                let log = SyncLog(syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional, bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(), errorMessage: "获取远程 MST 根失败：响应类型错误")
                try? StorageManager.shared.addSyncLog(log)
                return
            }
            
            // 重要：使用最新的 folder 对象计算状态，而不是传入的旧对象
            let (localMST, localMetadata, _, _) = await folderStatistics.calculateFullState(for: currentFolder)
            
            let currentPaths = Set(localMetadata.keys)
            let lastKnown = syncManager.lastKnownLocalPaths[syncID] ?? []
            
            // 更严格的删除检测
            var locallyDeleted: Set<String> = []
            let fileManager = FileManager.default
            for path in lastKnown {
                if !currentPaths.contains(path) {
                    let fileURL = currentFolder.localPath.appendingPathComponent(path)
                    if !fileManager.fileExists(atPath: fileURL.path) {
                        locallyDeleted.insert(path)
                    }
                }
            }
            
            // 更新 deletedPaths
            if !locallyDeleted.isEmpty {
                var dp = syncManager.deletedPaths[syncID] ?? []
                dp.formUnion(locallyDeleted)
                syncManager.deletedPaths[syncID] = dp
            }
            
            let mode = currentFolder.mode
            
            if localMST.rootHash == remoteHash && locallyDeleted.isEmpty {
                // 本地和远程已经同步
                syncManager.lastKnownLocalPaths[syncID] = currentPaths
                syncManager.updateFolderStatus(currentFolder.id, status: .synced, message: "Up to date", progress: 1.0)
                syncManager.syncIDManager.updateLastSyncedAt(syncID)
                syncManager.peerManager.updateOnlineStatus(peerID, isOnline: true)
                syncManager.updateDeviceCounts()
                // 记录成功日志（即使没有文件操作）
                let direction: SyncLog.Direction = mode == .uploadOnly ? .upload : (mode == .downloadOnly ? .download : .bidirectional)
                let log = SyncLog(syncID: syncID, folderID: folderID, peerID: peerID, direction: direction, bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(), syncedFiles: nil)
                try? StorageManager.shared.addSyncLog(log)
                return
            }
            
            // 2. Roots differ, get remote file list
            syncManager.updateFolderStatus(currentFolder.id, status: .syncing, message: "正在获取远程文件列表...", progress: 0.1)
            
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
                syncManager.updateFolderStatus(currentFolder.id, status: .error, message: "获取远程文件列表失败: \(error.localizedDescription)")
                // 记录错误日志
                let log = SyncLog(syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional, bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(), errorMessage: "获取远程文件列表失败: \(error.localizedDescription)")
                try? StorageManager.shared.addSyncLog(log)
                return
            }
            
            guard case .files(_, let remoteEntries) = filesRes else {
                print("[SyncEngine] ❌ [performSync] filesRes 不是 files 类型")
                // 记录错误日志
                let log = SyncLog(syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional, bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(), errorMessage: "获取远程文件列表失败：响应类型错误")
                try? StorageManager.shared.addSyncLog(log)
                return
            }
            
            let myPeerID = await MainActor.run { syncManager.p2pNode.peerID ?? "" }
            var totalOps = 0
            var completedOps = 0
            var syncedFiles: [SyncLog.SyncedFileInfo] = []
            
            // 定义下载和上传决策函数
            enum DownloadAction {
                case skip
                case overwrite
                case conflict
            }
            
            func downloadAction(remote: FileMetadata, local: FileMetadata?) -> DownloadAction {
                guard let loc = local else {
                    return .overwrite
                }
                if loc.hash == remote.hash {
                    return .skip
                }
                if let rvc = remote.vectorClock, let lvc = loc.vectorClock, !rvc.versions.isEmpty || !lvc.versions.isEmpty {
                    let cmp = lvc.compare(to: rvc)
                    switch cmp {
                    case .antecedent:
                        return .overwrite
                    case .successor, .equal:
                        return .skip
                    case .concurrent:
                        print("[SyncEngine] ⚠️ [downloadAction] VC 并发冲突，保存为冲突文件")
                        return .conflict
                    }
                }
                return remote.mtime > loc.mtime ? .overwrite : .skip
            }
            
            nonisolated func shouldUpload(local: FileMetadata, remote: FileMetadata?) -> Bool {
                guard let rem = remote else { return true }
                if local.hash == rem.hash {
                    return false
                }
                if let lvc = local.vectorClock, let rvc = rem.vectorClock, !lvc.versions.isEmpty || !rvc.versions.isEmpty {
                    let cmp = lvc.compare(to: rvc)
                    switch cmp {
                    case .successor:
                        return true
                    case .antecedent, .equal:
                        return false
                    case .concurrent:
                        let shouldUpload = local.mtime > rem.mtime
                        print("[SyncEngine] ⚠️ [shouldUpload] VC 并发冲突，使用 mtime 判断: 本地=\(local.mtime), 远程=\(rem.mtime), 结果=\(shouldUpload)")
                        return shouldUpload
                    }
                }
                return local.mtime > rem.mtime
            }
            
            // 合并已删除的文件集合：包括之前记录的删除和本次检测到的本地删除
            var deletedSet = syncManager.deletedPaths[syncID] ?? []
            deletedSet.formUnion(locallyDeleted) // 确保包含本次检测到的本地删除
            
            // 清理已确认删除的文件（远程也没有了）
            let confirmed = deletedSet.filter { !remoteEntries.keys.contains($0) }
            for p in confirmed { deletedSet.remove(p) }
            if deletedSet.isEmpty {
                syncManager.deletedPaths.removeValue(forKey: syncID)
            } else {
                syncManager.deletedPaths[syncID] = deletedSet
            }
            
            // 3. Download phase
            var changedFilesSet: Set<String> = []
            var conflictFilesSet: Set<String> = []
            var changedFiles: [(String, FileMetadata)] = []
            var conflictFiles: [(String, FileMetadata)] = []
            
            if mode == .twoWay || mode == .downloadOnly {
                for (path, remoteMeta) in remoteEntries {
                    // 重要：如果文件在本地被删除（locallyDeleted）或已标记删除（deletedSet），不应该下载
                    if locallyDeleted.contains(path) || deletedSet.contains(path) {
                        continue
                    }
                    if changedFilesSet.contains(path) || conflictFilesSet.contains(path) {
                        continue
                    }
                    switch downloadAction(remote: remoteMeta, local: localMetadata[path]) {
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
            var uploadConflictFiles: [(String, FileMetadata)] = [] // 上传时的冲突文件（需要先保存远程版本）
            
            if mode == .twoWay || mode == .uploadOnly {
                for (path, localMeta) in localMetadata {
                    if locallyDeleted.contains(path) {
                        continue
                    }
                    if filesToUploadSet.contains(path) {
                        continue
                    }
                    
                    // 检查是否有并发冲突
                    if let remoteMeta = remoteEntries[path],
                       let lvc = localMeta.vectorClock,
                       let rvc = remoteMeta.vectorClock,
                       !lvc.versions.isEmpty || !rvc.versions.isEmpty {
                        let cmp = lvc.compare(to: rvc)
                        if case .concurrent = cmp {
                            // 并发冲突：需要先保存远程版本为冲突文件，然后再上传本地版本
                            uploadConflictFiles.append((path, remoteMeta))
                            filesToUploadSet.insert(path)
                            filesToUpload.append((path, localMeta))
                            continue
                        }
                    }
                    
                    if shouldUpload(local: localMeta, remote: remoteEntries[path]) {
                        filesToUploadSet.insert(path)
                        filesToUpload.append((path, localMeta))
                    }
                }
            }
            totalOps += filesToUpload.count + uploadConflictFiles.count
            
            let toDelete = (mode == .twoWay || mode == .uploadOnly) ? locallyDeleted : []
            if !toDelete.isEmpty {
                totalOps += toDelete.count
            }
            
            if totalOps > 0 {
                syncManager.updateFolderStatus(currentFolder.id, status: .syncing, message: "准备同步 \(totalOps) 个操作...", progress: 0.2)
            }
            
            // 重要：先执行删除操作，确保远程删除后再进行下载，避免下载已删除的文件
            if !toDelete.isEmpty {
                syncManager.updateFolderStatus(currentFolder.id, status: .syncing, message: "正在删除 \(toDelete.count) 个文件...", progress: Double(completedOps) / Double(max(totalOps, 1)))
                
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
                        
                        let fileURL = currentFolder.localPath.appendingPathComponent(rel)
                        let fileName = (rel as NSString).lastPathComponent
                        let pathDir = (rel as NSString).deletingLastPathComponent
                        let folderName = pathDir.isEmpty ? nil : (pathDir as NSString).lastPathComponent
                        
                        var fileSize: Int64 = 0
                        if fileManager.fileExists(atPath: fileURL.path),
                           let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                           let size = attributes[FileAttributeKey.size] as? Int64 {
                            fileSize = size
                        }
                        
                        if fileManager.fileExists(atPath: fileURL.path) {
                            try? fileManager.removeItem(at: fileURL)
                        }
                        
                        try? StorageManager.shared.deleteVectorClock(syncID: syncID, path: rel)
                        
                        syncedFiles.append(SyncLog.SyncedFileInfo(
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
                        syncManager.deletedPaths.removeValue(forKey: syncID)
                    } else {
                        syncManager.deletedPaths[syncID] = deletedSet
                    }
                }
            }
            
            if totalOps == 0 {
                syncManager.lastKnownLocalPaths[syncID] = currentPaths
                syncManager.updateFolderStatus(currentFolder.id, status: .synced, message: "Up to date", progress: 1.0)
                syncManager.syncIDManager.updateLastSyncedAt(syncID)
                syncManager.peerManager.updateOnlineStatus(peerID, isOnline: true)
                syncManager.updateDeviceCounts()
                // 记录成功日志（即使没有文件操作）
                let direction: SyncLog.Direction = mode == .uploadOnly ? .upload : (mode == .downloadOnly ? .download : .bidirectional)
                let log = SyncLog(syncID: syncID, folderID: folderID, peerID: peerID, direction: direction, bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date(), syncedFiles: nil)
                try? StorageManager.shared.addSyncLog(log)
                return
            }
            
            // 5. Download changed files - 并行下载（删除操作已执行，不会下载已删除的文件）
            var totalDownloadBytes: Int64 = 0
            var totalUploadBytes: Int64 = 0
            
            await withTaskGroup(of: (Int64, SyncLog.SyncedFileInfo)?.self) { group in
                var activeDownloads = 0
                
                for (path, remoteMeta) in changedFiles {
                    if activeDownloads >= maxConcurrentTransfers {
                        if let result = await group.next(), let (bytes, fileInfo) = result {
                            totalDownloadBytes += bytes
                            syncedFiles.append(fileInfo)
                            completedOps += 1
                            activeDownloads -= 1
                            
                            syncManager.addDownloadBytes(bytes)
                            syncManager.updateFolderStatus(currentFolder.id, status: .syncing, message: "下载完成: \(completedOps)/\(totalOps)", progress: Double(completedOps) / Double(max(totalOps, 1)))
                        }
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
                               let attributes = try? fileManager.attributesOfItem(atPath: localURL.path),
                               let size = attributes[.size] as? Int64 {
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
                    if let (bytes, fileInfo) = result {
                        totalDownloadBytes += bytes
                        syncedFiles.append(fileInfo)
                        completedOps += 1
                        
                        syncManager.addDownloadBytes(bytes)
                        syncManager.updateFolderStatus(currentFolder.id, status: .syncing, message: "下载完成: \(completedOps)/\(totalOps)", progress: Double(completedOps) / Double(max(totalOps, 1)))
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
                            let parent = pathDir.isEmpty ? latestFolder.localPath : latestFolder.localPath.appendingPathComponent(pathDir)
                            let base = (fileName as NSString).deletingPathExtension
                            let ext = (fileName as NSString).pathExtension
                            let suffix = ext.isEmpty ? "" : ".\(ext)"
                            let conflictName = "\(base).conflict.\(String(peerID.prefix(8))).\(Int(remoteMeta.mtime.timeIntervalSince1970))\(suffix)"
                            let conflictURL = parent.appendingPathComponent(conflictName)
                            let fileManager = FileManager.default
                            
                            if !fileManager.fileExists(atPath: parent.path) {
                                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                            }
                            
                            guard fileManager.isWritableFile(atPath: parent.path) else {
                                throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "没有写入权限: \(parent.path)"])
                            }
                            
                            try data.write(to: conflictURL)
                            
                            let relConflict = pathDir.isEmpty ? conflictName : "\(pathDir)/\(conflictName)"
                            let cf = ConflictFile(syncID: syncID, relativePath: path, conflictPath: relConflict, remotePeerID: peerID)
                            try? StorageManager.shared.addConflict(cf)
                            
                            let folderName = pathDir.isEmpty ? nil : (pathDir as NSString).lastPathComponent
                            
                            return (Int64(data.count), SyncLog.SyncedFileInfo(
                                path: path,
                                fileName: fileName,
                                folderName: folderName,
                                size: Int64(data.count),
                                operation: .conflict
                            ))
                        } catch {
                            print("[SyncEngine] ❌ 下载冲突文件失败: \(path) - \(error.localizedDescription)")
                            return nil
                        }
                    }
                }
                
                for await result in group {
                    if let (bytes, fileInfo) = result {
                        totalDownloadBytes += bytes
                        syncedFiles.append(fileInfo)
                        completedOps += 1
                        
                        syncManager.addDownloadBytes(bytes)
                        syncManager.updateFolderStatus(currentFolder.id, status: .syncing, message: "冲突处理完成: \(completedOps)/\(totalOps)", progress: Double(completedOps) / Double(max(totalOps, 1)))
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
                            let parent = pathDir.isEmpty ? latestFolder.localPath : latestFolder.localPath.appendingPathComponent(pathDir)
                            let base = (fileName as NSString).deletingPathExtension
                            let ext = (fileName as NSString).pathExtension
                            let suffix = ext.isEmpty ? "" : ".\(ext)"
                            let conflictName = "\(base).conflict.\(String(peerID.prefix(8))).\(Int(remoteMeta.mtime.timeIntervalSince1970))\(suffix)"
                            let conflictURL = parent.appendingPathComponent(conflictName)
                            let fileManager = FileManager.default
                            
                            if !fileManager.fileExists(atPath: parent.path) {
                                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                            }
                            
                            guard fileManager.isWritableFile(atPath: parent.path) else {
                                throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "没有写入权限: \(parent.path)"])
                            }
                            
                            try data.write(to: conflictURL)
                            
                            let relConflict = pathDir.isEmpty ? conflictName : "\(pathDir)/\(conflictName)"
                            let cf = ConflictFile(syncID: syncID, relativePath: path, conflictPath: relConflict, remotePeerID: peerID)
                            try? StorageManager.shared.addConflict(cf)
                            
                            let folderName = pathDir.isEmpty ? nil : (pathDir as NSString).lastPathComponent
                            
                            return (Int64(data.count), SyncLog.SyncedFileInfo(
                                path: path,
                                fileName: fileName,
                                folderName: folderName,
                                size: Int64(data.count),
                                operation: .conflict
                            ))
                        } catch {
                            print("[SyncEngine] ⚠️ 保存上传冲突文件失败: \(path) - \(error.localizedDescription)")
                            return nil
                        }
                    }
                }
                
                for await result in group {
                    if let (bytes, fileInfo) = result {
                        totalDownloadBytes += bytes
                        syncedFiles.append(fileInfo)
                        completedOps += 1
                        
                        syncManager.addDownloadBytes(bytes)
                        syncManager.updateFolderStatus(currentFolder.id, status: .syncing, message: "冲突处理完成: \(completedOps)/\(totalOps)", progress: Double(completedOps) / Double(max(totalOps, 1)))
                    }
                }
            }
            
            // 6. Upload files to remote - 并行上传
            await withTaskGroup(of: (Int64, SyncLog.SyncedFileInfo)?.self) { group in
                var activeUploads = 0
                
                for (path, localMeta) in filesToUpload {
                    if activeUploads >= maxConcurrentTransfers {
                        if let result = await group.next(), let (bytes, fileInfo) = result {
                            totalUploadBytes += bytes
                            syncedFiles.append(fileInfo)
                            completedOps += 1
                            activeUploads -= 1
                            
                            syncManager.addUploadBytes(bytes)
                            syncManager.updateFolderStatus(currentFolder.id, status: .syncing, message: "上传完成: \(completedOps)/\(totalOps)", progress: Double(completedOps) / Double(max(totalOps, 1)))
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
                            let fileManager = FileManager.default
                            
                            guard fileManager.fileExists(atPath: fileURL.path) else {
                                print("[SyncEngine] ⚠️ 文件不存在（跳过上传）: \(fileURL.path)")
                                return nil
                            }
                            
                            guard fileManager.isReadableFile(atPath: fileURL.path) else {
                                print("[SyncEngine] ⚠️ 文件无读取权限（跳过上传）: \(fileURL.path)")
                                return nil
                            }
                            
                            let fileAttributes = try fileManager.attributesOfItem(atPath: fileURL.path)
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
                    if let (bytes, fileInfo) = result {
                        totalUploadBytes += bytes
                        syncedFiles.append(fileInfo)
                        completedOps += 1
                        
                        syncManager.addUploadBytes(bytes)
                        syncManager.updateFolderStatus(currentFolder.id, status: .syncing, message: "上传完成: \(completedOps)/\(totalOps)", progress: Double(completedOps) / Double(max(totalOps, 1)))
                    }
                }
            }
            
            // 同步完成后，重新计算本地状态并更新统计
            // 重要：使用最新的 folder 对象计算状态
            let (_, finalMetadata, finalFolderCount, finalTotalSize) = await folderStatistics.calculateFullState(for: currentFolder)
            let finalPaths = Set(finalMetadata.keys)
            syncManager.lastKnownLocalPaths[syncID] = finalPaths
            
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
            
            syncManager.updateFolderStatus(currentFolder.id, status: .synced, message: "同步完成", progress: 1.0)
            syncManager.syncIDManager.updateLastSyncedAt(syncID)
            syncManager.peerManager.updateOnlineStatus(peerID, isOnline: true)
            syncManager.updateDeviceCounts()
            syncManager.syncCooldown[syncID] = Date()
            let cooldownKey = "\(peerID):\(syncID)"
            syncManager.peerSyncCooldown[cooldownKey] = Date()
            
            let direction: SyncLog.Direction = mode == .uploadOnly ? .upload : (mode == .downloadOnly ? .download : .bidirectional)
            let log = SyncLog(syncID: syncID, folderID: folderID, peerID: peerID, direction: direction, bytesTransferred: totalBytes, filesCount: totalOps, startedAt: startedAt, completedAt: Date(), syncedFiles: syncedFiles.isEmpty ? nil : syncedFiles)
            try? StorageManager.shared.addSyncLog(log)
        } catch {
            let duration = Date().timeIntervalSince(startedAt)
            print("[SyncEngine] ❌ [performSync] 同步失败!")
            print("[SyncEngine]   文件夹: \(syncID)")
            print("[SyncEngine]   对等点: \(peerID.prefix(12))...")
            print("[SyncEngine]   耗时: \(String(format: "%.2f", duration)) 秒")
            print("[SyncEngine]   错误: \(error)")
            
            syncManager.removeFolderPeer(syncID, peerID: peerID)
            let errorMessage = error.localizedDescription.isEmpty ? "同步失败: \(error)" : error.localizedDescription
            syncManager.updateFolderStatus(currentFolder.id, status: .error, message: errorMessage)
            
            let log = SyncLog(syncID: syncID, folderID: folderID, peerID: peerID, direction: .bidirectional, bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: nil, errorMessage: error.localizedDescription)
            do {
                try StorageManager.shared.addSyncLog(log)
            } catch {
                print("[SyncEngine] ⚠️ 无法保存同步日志: \(error)")
            }
        }
    }
}
