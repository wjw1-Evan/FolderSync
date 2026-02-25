import Crypto
import Foundation

/// 文件传输管理器
/// 负责文件的上传和下载操作
@MainActor
class FileTransfer {
    weak var syncManager: SyncManager?

    private let chunkSyncThreshold: Int64 = 1 * 1024 * 1024  // 1MB，超过此大小的文件使用块级增量同步
    private let maxConcurrentTransfers = 8  // 最大并发传输数（上传/下载）
    private static let sharedCDC = FastCDC(min: 4096, avg: 16384, max: 65536)  // 复用实例，避免每次块级同步重复创建

    init(syncManager: SyncManager) {
        self.syncManager = syncManager
    }

    /// 全量下载文件
    func downloadFileFull(
        folder: SyncFolder,
        path: String,
        remoteMeta: FileMetadata,
        peerID: String
    ) async throws -> SyncLog.SyncedFileInfo {
        let syncManager = await MainActor.run { self.syncManager }
        guard let syncManager = syncManager else {
            throw NSError(
                domain: "FileTransfer", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"])
        }

        let fileName = (path as NSString).lastPathComponent
        let peer = syncManager.peerManager.getPeer(peerID)?.peerID
        guard let peer = peer else {
            throw NSError(
                domain: "FileTransfer", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Peer not found: \(peerID)"])
        }

        let dataRes: SyncResponse = try await syncManager.sendSyncRequest(
            .getFileData(syncID: folder.syncID, path: path),
            to: peer,
            peerID: peerID,
            timeout: 180.0,
            maxRetries: 3,
            folder: folder
        )

        guard case .fileData(_, _, let data) = dataRes else {
            // 记录详细的错误信息以便调试
            let errorMsg: String
            if case .error(let errorString) = dataRes {
                errorMsg = "下载响应错误: \(errorString)"
            } else {
                errorMsg = "下载响应格式错误: 期望 fileData，实际收到 \(String(describing: dataRes))"
            }
            AppLogger.syncPrint("[FileTransfer] ❌ \(errorMsg) - 文件: \(path)")
            throw NSError(
                domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        let localURL = folder.localPath.appendingPathComponent(path)
        let parentDir = localURL.deletingLastPathComponent()
        let fileManager = FileManager.default

        try? preparePathForWritingFile(
            fileURL: localURL, baseDir: folder.localPath, fileManager: fileManager)
        if !fileManager.fileExists(atPath: parentDir.path) {
            // 计算父目录的相对路径
            let parentRelativePath = (path as NSString).deletingLastPathComponent
            // 如果父目录路径不为空，检查并清除删除记录
            if !parentRelativePath.isEmpty && parentRelativePath != "." {
                let stateStore = await MainActor.run {
                    syncManager.getFileStateStore(for: folder.syncID)
                }
                if stateStore.getState(for: parentRelativePath)?.isDeleted == true {
                    AppLogger.syncPrint(
                        "[FileTransfer] 🔄 检测到需要创建父目录，清除父目录的删除记录: \(parentRelativePath)")
                    await MainActor.run {
                        stateStore.removeState(path: parentRelativePath)
                        // 同时从旧的删除记录格式中移除
                        var dp = syncManager.deletedPaths(for: folder.syncID)
                        dp.remove(parentRelativePath)
                        syncManager.updateDeletedPaths(dp, for: folder.syncID)
                    }
                }
            }
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        // 检查写入权限
        guard fileManager.isWritableFile(atPath: parentDir.path) else {
            throw NSError(
                domain: "FileTransfer", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "没有写入权限: \(parentDir.path)"])
        }

        // 标记同步写入冷却：即将把“下载数据”落地到本地，避免 FSEvents 把它误判为本地编辑
        syncManager.markSyncCooldown(syncID: folder.syncID, path: path)
        try data.write(to: localURL)

        // 设置文件的修改时间和创建时间与远程一致
        var attributes: [FileAttributeKey: Any] = [
            FileAttributeKey.modificationDate: remoteMeta.mtime
        ]
        if let creationDate = remoteMeta.creationDate {
            attributes[FileAttributeKey.creationDate] = creationDate
        }
        AppLogger.syncPrint("[FileTransfer] 🛠️ 设置文件属性: \(path), mtime=\(remoteMeta.mtime)")
        try fileManager.setAttributes(attributes, ofItemAtPath: localURL.path)

        // 合并 Vector Clock（使用 VectorClockManager）
        let localVC = VectorClockManager.getVectorClock(
            folderID: folder.id, syncID: folder.syncID, path: path)
        let remoteVC = remoteMeta.vectorClock
        let mergedVC = VectorClockManager.mergeVectorClocks(localVC: localVC, remoteVC: remoteVC)
        VectorClockManager.saveVectorClock(
            folderID: folder.id, syncID: folder.syncID, path: path, vc: mergedVC)

        let pathDir = (path as NSString).deletingLastPathComponent
        let folderName = pathDir.isEmpty ? nil : (pathDir as NSString).lastPathComponent

        syncManager.addDownloadBytes(Int64(data.count))

        return SyncLog.SyncedFileInfo(
            path: path,
            fileName: fileName,
            folderName: folderName,
            size: Int64(data.count),
            operation: .download
        )
    }

    // MARK: - Chunk Transfer Helpers

    private func downloadChunk(chunkHash: String, folder: SyncFolder, peer: PeerID, peerID: String)
        async -> (String, Data)?
    {
        do {
            let sm = await MainActor.run { self.syncManager }
            guard let sm = sm else { return nil }

            let chunkRes: SyncResponse = try await sm.sendSyncRequest(
                .getChunkData(syncID: folder.syncID, chunkHash: chunkHash),
                to: peer, peerID: peerID, timeout: 90.0, maxRetries: 3, folder: folder)

            guard case .chunkData(_, _, let data) = chunkRes else {
                return nil
            }

            try StorageManager.shared.saveBlock(hash: chunkHash, data: data)
            return (chunkHash, data)
        } catch {
            AppLogger.syncPrint(
                "[FileTransfer] ❌ 下载块失败: \(chunkHash) - \(error.localizedDescription)")
            return nil
        }
    }

    private func uploadChunk(chunk: Chunk, folder: SyncFolder, peer: PeerID, peerID: String) async
        -> (
            String, Int64
        )?
    {
        do {
            let sm = await MainActor.run { self.syncManager }
            guard let sm = sm else { return nil }

            let putChunkRes: SyncResponse = try await sm.sendSyncRequest(
                .putChunkData(syncID: folder.syncID, chunkHash: chunk.hash, data: chunk.data),
                to: peer, peerID: peerID, timeout: 180.0, maxRetries: 3, folder: folder)

            if case .chunkAck = putChunkRes {
                return (chunk.hash, Int64(chunk.data.count))
            }
        } catch {
            AppLogger.syncPrint(
                "[FileTransfer] ❌ 上传块失败: \(chunk.hash) - \(error.localizedDescription)")
        }
        return nil
    }

    /// 使用块级增量同步下载文件
    func downloadFileWithChunks(
        folder: SyncFolder,
        path: String,
        remoteMeta: FileMetadata,
        peerID: String
    ) async throws -> SyncLog.SyncedFileInfo {
        guard let syncManager = syncManager else {
            throw NSError(
                domain: "FileTransfer", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"])
        }

        let peer = syncManager.peerManager.getPeer(peerID)?.peerID
        guard let peer = peer else {
            throw NSError(
                domain: "FileTransfer", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Peer not found: \(peerID)"])
        }

        let fileName = (path as NSString).lastPathComponent
        // 1. 获取远程文件的块列表
        let chunksRes: SyncResponse = try await syncManager.sendSyncRequest(
            .getFileChunks(syncID: folder.syncID, path: path),
            to: peer,
            peerID: peerID,
            timeout: 90.0,
            maxRetries: 3,
            folder: folder
        )

        guard case .fileChunks(_, _, let remoteChunkHashes) = chunksRes else {
            // 如果块级同步失败，回退到全量下载
            // CRITICAL FIX: 防止大文件回退导致 OOM
            if remoteMeta.size > 100 * 1024 * 1024 {
                let errorMsg = "块级同步失败且文件过大 (\(remoteMeta.size) bytes)，禁止回退到全量下载以防止 OOM"
                AppLogger.syncPrint("[FileTransfer] ❌ \(errorMsg): \(path)")
                throw NSError(
                    domain: "FileTransfer", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: errorMsg])
            }

            if case .error(let errorString) = chunksRes {
                AppLogger.syncPrint("[FileTransfer] ⚠️ 块级同步失败，回退到全量下载: \(path) - \(errorString)")
            }
            return try await downloadFileFull(
                folder: folder,
                path: path,
                remoteMeta: remoteMeta,
                peerID: peerID
            )
        }

        // 2. 检查本地已有的块
        let hasBlocks = StorageManager.shared.hasBlocks(hashes: remoteChunkHashes)
        let missingHashes = remoteChunkHashes.filter { !(hasBlocks[$0] ?? false) }
        // 3. 下载缺失的块（控制并行度，避免淹没网络）
        var downloadedBytes: Int64 = 0
        if !missingHashes.isEmpty {
            let maxConcurrentChunks = 4
            await withTaskGroup(of: (String, Data)?.self) { group in
                var activeChunks = 0
                var hashIterator = missingHashes.makeIterator()

                // 填充初始任务
                for _ in 0..<maxConcurrentChunks {
                    if let chunkHash = hashIterator.next() {
                        activeChunks += 1
                        group.addTask { [weak self] in
                            return await self?.downloadChunk(
                                chunkHash: chunkHash, folder: folder, peer: peer, peerID: peerID)
                        }
                    }
                }

                // 处理剩余任务
                while activeChunks > 0 {
                    if let result = await group.next() {
                        activeChunks -= 1
                        if let (_, data) = result {
                            downloadedBytes += Int64(data.count)
                            syncManager.addDownloadBytes(Int64(data.count))
                        }

                        // 补充新任务
                        if let chunkHash = hashIterator.next() {
                            activeChunks += 1
                            group.addTask { [weak self] in
                                return await self?.downloadChunk(
                                    chunkHash: chunkHash, folder: folder, peer: peer, peerID: peerID
                                )
                            }
                        }
                    }
                }
            }
        }

        // 4. 从块重建文件
        let localURL = folder.localPath.appendingPathComponent(path)
        let parentDir = localURL.deletingLastPathComponent()
        let fileManager = FileManager.default

        try? preparePathForWritingFile(
            fileURL: localURL, baseDir: folder.localPath, fileManager: fileManager)
        if !fileManager.fileExists(atPath: parentDir.path) {
            // 计算父目录的相对路径
            let parentRelativePath = (path as NSString).deletingLastPathComponent
            // 如果父目录路径不为空，检查并清除删除记录
            if !parentRelativePath.isEmpty && parentRelativePath != "." {
                let stateStore = await MainActor.run {
                    syncManager.getFileStateStore(for: folder.syncID)
                }
                if stateStore.getState(for: parentRelativePath)?.isDeleted == true {
                    AppLogger.syncPrint(
                        "[FileTransfer] 🔄 检测到需要创建父目录，清除父目录的删除记录: \(parentRelativePath)")
                    await MainActor.run {
                        stateStore.removeState(path: parentRelativePath)
                        // 同时从旧的删除记录格式中移除
                        var dp = syncManager.deletedPaths(for: folder.syncID)
                        dp.remove(parentRelativePath)
                        syncManager.updateDeletedPaths(dp, for: folder.syncID)
                    }
                }
            }
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        guard fileManager.isWritableFile(atPath: parentDir.path) else {
            throw NSError(
                domain: "FileTransfer", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "没有写入权限: \(parentDir.path)"])
        }

        // 从块重建文件
        var fileData = Data()
        for chunkHash in remoteChunkHashes {
            guard let chunkData = try StorageManager.shared.getBlock(hash: chunkHash) else {
                throw NSError(
                    domain: "FileTransfer", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "块不存在: \(chunkHash)"])
            }
            fileData.append(chunkData)
        }

        // 标记同步写入冷却：即将把“下载数据”落地到本地，避免 FSEvents 把它误判为本地编辑
        syncManager.markSyncCooldown(syncID: folder.syncID, path: path)
        try fileData.write(to: localURL, options: [.atomic])

        // 设置文件的修改时间和创建时间与远程一致
        var attributes: [FileAttributeKey: Any] = [
            FileAttributeKey.modificationDate: remoteMeta.mtime
        ]
        if let creationDate = remoteMeta.creationDate {
            attributes[FileAttributeKey.creationDate] = creationDate
        }
        AppLogger.syncPrint("[FileTransfer] 🛠️ 设置文件属性: \(path), mtime=\(remoteMeta.mtime)")
        try fileManager.setAttributes(attributes, ofItemAtPath: localURL.path)

        // 合并 Vector Clock（使用 VectorClockManager）
        let localVC = VectorClockManager.getVectorClock(
            folderID: folder.id, syncID: folder.syncID, path: path)
        let remoteVC = remoteMeta.vectorClock
        let mergedVC = VectorClockManager.mergeVectorClocks(localVC: localVC, remoteVC: remoteVC)
        VectorClockManager.saveVectorClock(
            folderID: folder.id, syncID: folder.syncID, path: path, vc: mergedVC)

        let pathDir = (path as NSString).deletingLastPathComponent
        let folderName = pathDir.isEmpty ? nil : (pathDir as NSString).lastPathComponent

        return SyncLog.SyncedFileInfo(
            path: path,
            fileName: fileName,
            folderName: folderName,
            size: Int64(fileData.count),
            operation: .download
        )
    }

    /// 全量上传文件
    func uploadFileFull(
        folder: SyncFolder,
        path: String,
        localMeta: FileMetadata,
        peerID: String
    ) async throws -> SyncLog.SyncedFileInfo {
        guard let syncManager = syncManager else {
            throw NSError(
                domain: "FileTransfer", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"])
        }

        let peer = syncManager.peerManager.getPeer(peerID)?.peerID
        guard let peer = peer else {
            throw NSError(
                domain: "FileTransfer", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Peer not found: \(peerID)"])
        }

        let myPeerID = syncManager.p2pNode.peerID?.b58String ?? ""

        let fileName = (path as NSString).lastPathComponent
        let fileURL = folder.localPath.appendingPathComponent(path)
        let fileManager = FileManager.default

        // 检查文件是否存在和可读
        guard fileManager.fileExists(atPath: fileURL.path) else {
            AppLogger.syncPrint("[FileTransfer] ❌ 文件不存在，跳过上传: \(path)")
            throw NSError(
                domain: "FileTransfer", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "文件不存在: \(path)"])
        }

        // 检查是否为目录，如果是目录则跳过（目录不应该被上传）
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            // 跳过目录上传
            throw NSError(
                domain: "FileTransfer", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "路径是目录，不是文件: \(path)"])
        }

        guard fileManager.isReadableFile(atPath: fileURL.path) else {
            AppLogger.syncPrint("[FileTransfer] ❌ 文件无读取权限: \(path)")
            throw NSError(
                domain: "FileTransfer", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "文件无读取权限: \(path)"])
        }

        // (Removed redundant shouldUpload check as SyncEngine handles planning)

        let data = try Data(contentsOf: fileURL)

        // 准备 Vector Clock（在发送前准备，但只在成功后保存）
        // 注意：Vector Clock 应该在文件实际修改时更新，这里只是确保有最新的 VC
        let currentVC =
            VectorClockManager.getVectorClock(
                folderID: folder.id, syncID: folder.syncID, path: path)
            ?? VectorClock()
        var vc = currentVC
        vc.increment(for: myPeerID)

        // 发送文件数据（携带更新后的 VC）
        let putRes: SyncResponse = try await syncManager.sendSyncRequest(
            .putFileData(syncID: folder.syncID, path: path, data: data, vectorClock: vc),
            to: peer,
            peerID: peerID,
            timeout: 180.0,
            maxRetries: 3,
            folder: folder
        )

        guard case .putAck = putRes else {
            // 发送失败，不保存 VC（保持一致性）
            // 记录详细的错误信息以便调试
            let errorMsg: String
            if case .error(let errorString) = putRes {
                errorMsg = "上传响应错误: \(errorString)"
            } else {
                errorMsg = "上传响应格式错误: 期望 putAck，实际收到 \(String(describing: putRes))"
            }
            AppLogger.syncPrint("[FileTransfer] ❌ \(errorMsg) - 文件: \(path)")
            throw NSError(
                domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        // 发送成功后才保存 Vector Clock（确保一致性）
        VectorClockManager.saveVectorClock(
            folderID: folder.id, syncID: folder.syncID, path: path, vc: vc)

        let pathDir = (path as NSString).deletingLastPathComponent
        let folderName = pathDir.isEmpty ? nil : (pathDir as NSString).lastPathComponent

        syncManager.addUploadBytes(Int64(data.count))

        return SyncLog.SyncedFileInfo(
            path: path,
            fileName: fileName,
            folderName: folderName,
            size: Int64(data.count),
            operation: .upload
        )
    }

    /// 使用块级增量同步上传文件
    func uploadFileWithChunks(
        folder: SyncFolder,
        path: String,
        localMeta: FileMetadata,
        peerID: String
    ) async throws -> SyncLog.SyncedFileInfo {
        guard let syncManager = syncManager else {
            throw NSError(
                domain: "FileTransfer", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"])
        }

        let peer = syncManager.peerManager.getPeer(peerID)?.peerID
        guard let peer = peer else {
            throw NSError(
                domain: "FileTransfer", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Peer not found: \(peerID)"])
        }

        let myPeerID = syncManager.p2pNode.peerID?.b58String ?? ""

        let fileName = (path as NSString).lastPathComponent
        let fileURL = folder.localPath.appendingPathComponent(path)
        let fileManager = FileManager.default

        // 检查文件是否存在和可读
        guard fileManager.fileExists(atPath: fileURL.path) else {
            AppLogger.syncPrint("[FileTransfer] ❌ 文件不存在，跳过上传: \(path)")
            throw NSError(
                domain: "FileTransfer", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "文件不存在: \(path)"])
        }

        // 检查是否为目录，如果是目录则跳过（目录不应该被上传）
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            // 跳过目录上传
            throw NSError(
                domain: "FileTransfer", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "路径是目录，不是文件: \(path)"])
        }

        guard fileManager.isReadableFile(atPath: fileURL.path) else {
            AppLogger.syncPrint("[FileTransfer] ❌ 文件无读取权限: \(path)")
            throw NSError(
                domain: "FileTransfer", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "文件无读取权限: \(path)"])
        }

        // (Removed redundant shouldUpload check as SyncEngine handles planning)

        let chunks = try Self.sharedCDC.chunk(fileURL: fileURL)
        let chunkHashes = chunks.map { $0.hash }

        // 2. 保存块到本地存储（用于后续去重）
        for chunk in chunks {
            if !StorageManager.shared.hasBlock(hash: chunk.hash) {
                try StorageManager.shared.saveBlock(hash: chunk.hash, data: chunk.data)
            }
        }

        // 3. 准备 Vector Clock（在发送前准备，但只在成功后保存）
        // 注意：Vector Clock 应该在文件实际修改时更新，这里只是确保有最新的 VC
        let currentVC =
            VectorClockManager.getVectorClock(
                folderID: folder.id, syncID: folder.syncID, path: path)
            ?? VectorClock()
        var vc = currentVC
        vc.increment(for: myPeerID)

        // 4. 上传块列表（携带更新后的 VC）
        let chunksRes: SyncResponse = try await syncManager.sendSyncRequest(
            .putFileChunks(
                syncID: folder.syncID, path: path, chunkHashes: chunkHashes, vectorClock: vc),
            to: peer,
            peerID: peerID,
            timeout: 90.0,
            maxRetries: 3,
            folder: folder
        )

        var uploadedBytes: Int64 = 0
        var uploadSucceeded = false

        // 检查响应类型
        switch chunksRes {
        case .fileChunksAck:
            // 所有块都存在，文件已重建完成，没有实际传输字节
            uploadedBytes = 0
            uploadSucceeded = true

        case .error(let errorMsg) where errorMsg.hasPrefix("缺失块:"):
            // 远程缺失某些块，需要上传这些块
            let missingHashesStr = errorMsg.replacingOccurrences(of: "缺失块: ", with: "")
            let missingHashes = missingHashesStr.split(separator: ",").map { String($0) }

            // 并行上传缺失的块（控制并行度）
            let maxConcurrentChunks = 4
            await withTaskGroup(of: (String, Int64)?.self) { group in
                var activeChunks = 0
                var hashIterator = missingHashes.makeIterator()

                // 填充初始任务
                for _ in 0..<maxConcurrentChunks {
                    if let chunkHash = hashIterator.next() {
                        activeChunks += 1
                        group.addTask { [weak self] in
                            guard let self = self,
                                let chunk = chunks.first(where: { $0.hash == chunkHash })
                            else { return nil }
                            return await self.uploadChunk(
                                chunk: chunk, folder: folder, peer: peer, peerID: peerID)
                        }
                    }
                }

                // 处理剩余任务
                while activeChunks > 0 {
                    if let result = await group.next() {
                        activeChunks -= 1
                        if let (_, bytes) = result {
                            uploadedBytes += bytes
                            syncManager.addUploadBytes(bytes)
                        }

                        // 补充新任务
                        if let chunkHash = hashIterator.next() {
                            activeChunks += 1
                            group.addTask { [weak self] in
                                guard let self = self,
                                    let chunk = chunks.first(where: { $0.hash == chunkHash })
                                else { return nil }
                                return await self.uploadChunk(
                                    chunk: chunk, folder: folder, peer: peer, peerID: peerID)
                            }
                        }
                    }
                }
            }

            // 上传完缺失的块后，再次发送 putFileChunks 确认
            let syncManagerForConfirm = await MainActor.run { self.syncManager }
            guard let syncManagerForConfirm = syncManagerForConfirm else {
                throw NSError(
                    domain: "FileTransfer", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"])
            }
            let confirmRes: SyncResponse = try await syncManagerForConfirm.sendSyncRequest(
                .putFileChunks(
                    syncID: folder.syncID, path: path, chunkHashes: chunkHashes, vectorClock: vc),
                to: peer,
                peerID: peerID,
                timeout: 90.0,
                maxRetries: 3,
                folder: folder
            )

            guard case .fileChunksAck = confirmRes else {
                // 确认失败，回退到全量上传（不保存 VC，因为上传失败）
                if case .error(let errorString) = confirmRes {
                    AppLogger.syncPrint(
                        "[FileTransfer] ⚠️ 块级同步确认失败，回退到全量上传: \(path) - \(errorString)")
                }
                return try await uploadFileFull(
                    folder: folder,
                    path: path,
                    localMeta: localMeta,
                    peerID: peerID
                )
            }
            uploadSucceeded = true

        default:
            // 其他错误，回退到全量上传（不保存 VC，因为上传失败）
            // CRITICAL FIX: 防止大文件回退导致 OOM
            if localMeta.size > 100 * 1024 * 1024 {
                let errorMsg = "块级同步失败且文件过大 (\(localMeta.size) bytes)，禁止回退到全量上传以防止 OOM"
                AppLogger.syncPrint("[FileTransfer] ❌ \(errorMsg): \(path)")
                throw NSError(
                    domain: "FileTransfer", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: errorMsg])
            }

            AppLogger.syncPrint("[FileTransfer] ⚠️ 块级同步失败，回退到全量上传: \(path)")
            return try await uploadFileFull(
                folder: folder,
                path: path,
                localMeta: localMeta,
                peerID: peerID
            )
        }

        // 只有在成功上传后才保存 Vector Clock（确保一致性）
        if uploadSucceeded {
            VectorClockManager.saveVectorClock(
                folderID: folder.id, syncID: folder.syncID, path: path, vc: vc)
        }

        let pathDir = (path as NSString).deletingLastPathComponent
        let folderName = pathDir.isEmpty ? nil : (pathDir as NSString).lastPathComponent

        return SyncLog.SyncedFileInfo(
            path: path,
            fileName: fileName,
            folderName: folderName,
            size: Int64(chunks.reduce(0) { $0 + $1.data.count }),
            operation: .upload
        )
    }

    /// 判断是否应该使用块级同步
    func shouldUseChunkSync(fileSize: Int64) -> Bool {
        return fileSize > chunkSyncThreshold
    }
}
