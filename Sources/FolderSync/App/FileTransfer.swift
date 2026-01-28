import Foundation
import Crypto

/// 文件传输管理器
/// 负责文件的上传和下载操作
@MainActor
class FileTransfer {
    weak var syncManager: SyncManager?
    
    private let chunkSyncThreshold: Int64 = 1 * 1024 * 1024 // 1MB，超过此大小的文件使用块级增量同步
    private let maxConcurrentTransfers = 8 // 最大并发传输数（上传/下载）
    
    init(syncManager: SyncManager) {
        self.syncManager = syncManager
    }
    
    /// 全量下载文件
    func downloadFileFull(
        path: String,
        remoteMeta: FileMetadata,
        folder: SyncFolder,
        peer: PeerID,
        peerID: String,
        localMetadata: [String: FileMetadata]
    ) async throws -> (Int64, SyncLog.SyncedFileInfo) {
        let syncManager = await MainActor.run { self.syncManager }
        guard let syncManager = syncManager else {
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"])
        }
        
        let fileName = (path as NSString).lastPathComponent
        print("[FileTransfer] ⬇️ [DEBUG] 开始全量下载文件: 路径=\(path), syncID=\(folder.syncID), peer=\(peerID.prefix(12))..., 远程大小=\(remoteMeta.hash.prefix(16))...")
        
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
            print("[FileTransfer] ❌ [DEBUG] \(errorMsg) - 文件: \(path)")
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        print("[FileTransfer] ✅ [DEBUG] 文件数据接收成功: 路径=\(path), 数据大小=\(data.count) bytes")
        
        let localURL = folder.localPath.appendingPathComponent(path)
        let parentDir = localURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        
        // 检查并创建父目录
        // 如果父目录不存在，需要检查是否有删除记录，如果有则清除（因为文件的创建意味着父目录不再被删除）
        if !fileManager.fileExists(atPath: parentDir.path) {
            // 计算父目录的相对路径
            let parentRelativePath = (path as NSString).deletingLastPathComponent
            // 如果父目录路径不为空，检查并清除删除记录
            if !parentRelativePath.isEmpty && parentRelativePath != "." {
                let stateStore = await MainActor.run { syncManager.getFileStateStore(for: folder.syncID) }
                if stateStore.getState(for: parentRelativePath)?.isDeleted == true {
                    print("[FileTransfer] 🔄 检测到需要创建父目录，清除父目录的删除记录: \(parentRelativePath)")
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
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "没有写入权限: \(parentDir.path)"])
        }
        
        // 标记同步写入冷却：即将把“下载数据”落地到本地，避免 FSEvents 把它误判为本地编辑
        syncManager.markSyncCooldown(syncID: folder.syncID, path: path)
        try data.write(to: localURL)
        
        // 合并 Vector Clock（使用 VectorClockManager）
        let localVC = localMetadata[path]?.vectorClock
        let remoteVC = remoteMeta.vectorClock
        let mergedVC = VectorClockManager.mergeVectorClocks(localVC: localVC, remoteVC: remoteVC)
        VectorClockManager.saveVectorClock(folderID: folder.id, syncID: folder.syncID, path: path, vc: mergedVC)
        
        let pathDir = (path as NSString).deletingLastPathComponent
        let folderName = pathDir.isEmpty ? nil : (pathDir as NSString).lastPathComponent
        
        return (Int64(data.count), SyncLog.SyncedFileInfo(
            path: path,
            fileName: fileName,
            folderName: folderName,
            size: Int64(data.count),
            operation: .download
        ))
    }
    
    /// 使用块级增量同步下载文件
    func downloadFileWithChunks(
        path: String,
        remoteMeta: FileMetadata,
        folder: SyncFolder,
        peer: PeerID,
        peerID: String,
        localMetadata: [String: FileMetadata]
    ) async throws -> (Int64, SyncLog.SyncedFileInfo) {
        let syncManager = await MainActor.run { self.syncManager }
        guard let syncManager = syncManager else {
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"])
        }
        
        let fileName = (path as NSString).lastPathComponent
        print("[FileTransfer] ⬇️ [DEBUG] 开始块级下载文件: 路径=\(path), syncID=\(folder.syncID), peer=\(peerID.prefix(12))...")
        
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
            if case .error(let errorString) = chunksRes {
                print("[FileTransfer] ⚠️ [DEBUG] 块级同步失败（错误响应），回退到全量下载: \(path) - \(errorString)")
            } else {
                print("[FileTransfer] ⚠️ [DEBUG] 块级同步失败（响应格式错误），回退到全量下载: \(path) - 收到: \(String(describing: chunksRes))")
            }
            return try await downloadFileFull(path: path, remoteMeta: remoteMeta, folder: folder, peer: peer, peerID: peerID, localMetadata: localMetadata)
        }
        
        print("[FileTransfer] 📦 [DEBUG] 获取到远程块列表: 路径=\(path), 块数=\(remoteChunkHashes.count)")
        
        // 2. 检查本地已有的块
        let hasBlocks = StorageManager.shared.hasBlocks(hashes: remoteChunkHashes)
        let missingHashes = remoteChunkHashes.filter { !(hasBlocks[$0] ?? false) }
        print("[FileTransfer] 📊 [DEBUG] 块检查结果: 路径=\(path), 总块数=\(remoteChunkHashes.count), 已有块数=\(remoteChunkHashes.count - missingHashes.count), 缺失块数=\(missingHashes.count)")
        
        // 3. 下载缺失的块（并行下载）
        var downloadedBytes: Int64 = 0
        if !missingHashes.isEmpty {
            print("[FileTransfer] ⬇️ [DEBUG] 开始下载缺失块: 路径=\(path), 缺失块数=\(missingHashes.count)")
            await withTaskGroup(of: (String, Data)?.self) { group in
                for chunkHash in missingHashes {
                    group.addTask { [weak self] in
                        guard let self = self else { return nil }
                        do {
                            let syncManager = await MainActor.run { self.syncManager }
                            guard let syncManager = syncManager else { return nil }
                            
                            print("[FileTransfer] ⬇️ [DEBUG] 下载块: 路径=\(path), 块哈希=\(chunkHash.prefix(8))...")
                            let chunkRes: SyncResponse = try await syncManager.sendSyncRequest(
                                .getChunkData(syncID: folder.syncID, chunkHash: chunkHash),
                                to: peer,
                                peerID: peerID,
                                timeout: 90.0,
                                maxRetries: 3,
                                folder: folder
                            )
                            
                            guard case .chunkData(_, _, let data) = chunkRes else {
                                if case .error(let errorString) = chunkRes {
                                    print("[FileTransfer] ❌ [DEBUG] 获取块数据失败: 路径=\(path), 块哈希=\(chunkHash.prefix(8))..., 错误=\(errorString)")
                                } else {
                                    print("[FileTransfer] ❌ [DEBUG] 获取块数据响应格式错误: 路径=\(path), 块哈希=\(chunkHash.prefix(8))..., 收到=\(String(describing: chunkRes))")
                                }
                                return nil
                            }
                            
                            // 保存块
                            try StorageManager.shared.saveBlock(hash: chunkHash, data: data)
                            print("[FileTransfer] ✅ [DEBUG] 块下载成功: 路径=\(path), 块哈希=\(chunkHash.prefix(8))..., 大小=\(data.count) bytes")
                            return (chunkHash, data)
                        } catch {
                            print("[FileTransfer] ❌ [DEBUG] 下载块失败: 路径=\(path), 块哈希=\(chunkHash.prefix(8))..., 错误=\(error.localizedDescription)")
                            return nil
                        }
                    }
                }
                
                for await result in group {
                    if let (_, data) = result {
                        downloadedBytes += Int64(data.count)
                        print("[FileTransfer] 📊 [DEBUG] 块下载进度: 路径=\(path), 已下载=\(downloadedBytes) bytes")
                    }
                }
            }
            print("[FileTransfer] ✅ [DEBUG] 所有缺失块下载完成: 路径=\(path), 总下载=\(downloadedBytes) bytes")
        } else {
            print("[FileTransfer] ℹ️ [DEBUG] 所有块已存在，无需下载: 路径=\(path)")
        }
        
        // 4. 从块重建文件
        let localURL = folder.localPath.appendingPathComponent(path)
        let parentDir = localURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        
        // 如果父目录不存在，需要检查是否有删除记录，如果有则清除（因为文件的创建意味着父目录不再被删除）
        if !fileManager.fileExists(atPath: parentDir.path) {
            // 计算父目录的相对路径
            let parentRelativePath = (path as NSString).deletingLastPathComponent
            // 如果父目录路径不为空，检查并清除删除记录
            if !parentRelativePath.isEmpty && parentRelativePath != "." {
                let stateStore = await MainActor.run { syncManager.getFileStateStore(for: folder.syncID) }
                if stateStore.getState(for: parentRelativePath)?.isDeleted == true {
                    print("[FileTransfer] 🔄 检测到需要创建父目录，清除父目录的删除记录: \(parentRelativePath)")
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
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "没有写入权限: \(parentDir.path)"])
        }
        
        // 从块重建文件
        var fileData = Data()
        for chunkHash in remoteChunkHashes {
            guard let chunkData = try StorageManager.shared.getBlock(hash: chunkHash) else {
                throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "块不存在: \(chunkHash)"])
            }
            fileData.append(chunkData)
        }
        
        // 标记同步写入冷却：即将把“下载数据”落地到本地，避免 FSEvents 把它误判为本地编辑
        syncManager.markSyncCooldown(syncID: folder.syncID, path: path)
        try fileData.write(to: localURL, options: [.atomic])
        
        // 合并 Vector Clock（使用 VectorClockManager）
        let localVC = localMetadata[path]?.vectorClock
        let remoteVC = remoteMeta.vectorClock
        let mergedVC = VectorClockManager.mergeVectorClocks(localVC: localVC, remoteVC: remoteVC)
        VectorClockManager.saveVectorClock(folderID: folder.id, syncID: folder.syncID, path: path, vc: mergedVC)
        
        let pathDir = (path as NSString).deletingLastPathComponent
        let folderName = pathDir.isEmpty ? nil : (pathDir as NSString).lastPathComponent
        
        return (Int64(fileData.count), SyncLog.SyncedFileInfo(
            path: path,
            fileName: fileName,
            folderName: folderName,
            size: Int64(fileData.count),
            operation: .download
        ))
    }
    
    /// 全量上传文件
    func uploadFileFull(
        path: String,
        localMeta: FileMetadata,
        folder: SyncFolder,
        peer: PeerID,
        peerID: String,
        myPeerID: String,
        remoteEntries: [String: FileMetadata],
        shouldUpload: (FileMetadata, FileMetadata?, String) -> Bool
    ) async throws -> (Int64, SyncLog.SyncedFileInfo) {
        let syncManager = await MainActor.run { self.syncManager }
        guard let syncManager = syncManager else {
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"])
        }
        
        let fileName = (path as NSString).lastPathComponent
        let fileURL = folder.localPath.appendingPathComponent(path)
        let fileManager = FileManager.default
        
        print("[FileTransfer] ⬆️ [DEBUG] 开始全量上传文件: 路径=\(path), syncID=\(folder.syncID), peer=\(peerID.prefix(12))...")
        
        // 检查文件是否存在和可读
        guard fileManager.fileExists(atPath: fileURL.path) else {
            print("[FileTransfer] ❌ [DEBUG] 文件不存在，跳过上传: 路径=\(path)")
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "文件不存在: \(path)"])
        }
        
        // 检查是否为目录，如果是目录则跳过（目录不应该被上传）
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            print("[FileTransfer] ⏭️ [DEBUG] 跳过目录上传: \(path)")
            throw NSError(domain: "FileTransfer", code: -2, userInfo: [NSLocalizedDescriptionKey: "路径是目录，不是文件: \(path)"])
        }
        
        guard fileManager.isReadableFile(atPath: fileURL.path) else {
            print("[FileTransfer] ❌ [DEBUG] 文件无读取权限，跳过上传: 路径=\(path)")
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "文件无读取权限: \(path)"])
        }
        
        // 再次检查是否需要上传（可能在准备上传时文件已被同步）
        if let remoteMeta = remoteEntries[path], !shouldUpload(localMeta, remoteMeta, path) {
            print("[FileTransfer] ⏭️ [DEBUG] 文件已同步，跳过上传: 路径=\(path)")
            throw NSError(domain: "FileTransfer", code: -2, userInfo: [NSLocalizedDescriptionKey: "文件已同步，跳过上传"])
        }
        
        let data = try Data(contentsOf: fileURL)
        print("[FileTransfer] 📦 [DEBUG] 文件数据已加载: 路径=\(path), 大小=\(data.count) bytes")
        
        // 准备 Vector Clock（在发送前准备，但只在成功后保存）
        // 注意：Vector Clock 应该在文件实际修改时更新，这里只是确保有最新的 VC
        let currentVC =
            VectorClockManager.getVectorClock(folderID: folder.id, syncID: folder.syncID, path: path)
            ?? VectorClock()
        var vc = currentVC
        vc.increment(for: myPeerID)
        
        // 发送文件数据（携带更新后的 VC）
        print("[FileTransfer] 📤 [DEBUG] 发送文件数据: 路径=\(path), 大小=\(data.count) bytes")
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
            print("[FileTransfer] ❌ [DEBUG] \(errorMsg) - 文件: \(path)")
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        // 发送成功后才保存 Vector Clock（确保一致性）
        VectorClockManager.saveVectorClock(folderID: folder.id, syncID: folder.syncID, path: path, vc: vc)
        print("[FileTransfer] ✅ [DEBUG] 文件上传成功: 路径=\(path), 大小=\(data.count) bytes, VC已保存")
        
        let pathDir = (path as NSString).deletingLastPathComponent
        let folderName = pathDir.isEmpty ? nil : (pathDir as NSString).lastPathComponent
        
        return (Int64(data.count), SyncLog.SyncedFileInfo(
            path: path,
            fileName: fileName,
            folderName: folderName,
            size: Int64(data.count),
            operation: .upload
        ))
    }
    
    /// 使用块级增量同步上传文件
    func uploadFileWithChunks(
        path: String,
        localMeta: FileMetadata,
        folder: SyncFolder,
        peer: PeerID,
        peerID: String,
        myPeerID: String,
        remoteEntries: [String: FileMetadata],
        shouldUpload: (FileMetadata, FileMetadata?, String) -> Bool
    ) async throws -> (Int64, SyncLog.SyncedFileInfo) {
        let syncManager = await MainActor.run { self.syncManager }
        guard let syncManager = syncManager else {
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"])
        }
        
        let fileName = (path as NSString).lastPathComponent
        let fileURL = folder.localPath.appendingPathComponent(path)
        let fileManager = FileManager.default
        
        print("[FileTransfer] ⬆️ [DEBUG] 开始块级上传文件: 路径=\(path), syncID=\(folder.syncID), peer=\(peerID.prefix(12))...")
        
        // 检查文件是否存在和可读
        guard fileManager.fileExists(atPath: fileURL.path) else {
            print("[FileTransfer] ❌ [DEBUG] 文件不存在，跳过上传: 路径=\(path)")
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "文件不存在: \(path)"])
        }
        
        // 检查是否为目录，如果是目录则跳过（目录不应该被上传）
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            print("[FileTransfer] ⏭️ [DEBUG] 跳过目录上传: \(path)")
            throw NSError(domain: "FileTransfer", code: -2, userInfo: [NSLocalizedDescriptionKey: "路径是目录，不是文件: \(path)"])
        }
        
        guard fileManager.isReadableFile(atPath: fileURL.path) else {
            print("[FileTransfer] ❌ [DEBUG] 文件无读取权限，跳过上传: 路径=\(path)")
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "文件无读取权限: \(path)"])
        }
        
        // 再次检查是否需要上传
        if let remoteMeta = remoteEntries[path], !shouldUpload(localMeta, remoteMeta, path) {
            print("[FileTransfer] ⏭️ [DEBUG] 文件已同步，跳过上传: 路径=\(path)")
            throw NSError(domain: "FileTransfer", code: -2, userInfo: [NSLocalizedDescriptionKey: "文件已同步，跳过上传"])
        }
        
        // 1. 使用 FastCDC 切分文件为块
        print("[FileTransfer] 🔪 [DEBUG] 切分文件为块: 路径=\(path)")
        let cdc = FastCDC(min: 4096, avg: 16384, max: 65536)
        let chunks = try cdc.chunk(fileURL: fileURL)
        let chunkHashes = chunks.map { $0.hash }
        print("[FileTransfer] 📦 [DEBUG] 文件切分完成: 路径=\(path), 块数=\(chunks.count), 总大小=\(chunks.reduce(0) { $0 + $1.data.count }) bytes")
        
        // 2. 保存块到本地存储（用于后续去重）
        for chunk in chunks {
            if !StorageManager.shared.hasBlock(hash: chunk.hash) {
                try StorageManager.shared.saveBlock(hash: chunk.hash, data: chunk.data)
            }
        }
        
        // 3. 准备 Vector Clock（在发送前准备，但只在成功后保存）
        // 注意：Vector Clock 应该在文件实际修改时更新，这里只是确保有最新的 VC
        let currentVC =
            VectorClockManager.getVectorClock(folderID: folder.id, syncID: folder.syncID, path: path)
            ?? VectorClock()
        var vc = currentVC
        vc.increment(for: myPeerID)
        
        // 4. 上传块列表（携带更新后的 VC）
        print("[FileTransfer] 📤 [DEBUG] 上传块列表: 路径=\(path), 块数=\(chunkHashes.count)")
        let chunksRes: SyncResponse = try await syncManager.sendSyncRequest(
            .putFileChunks(syncID: folder.syncID, path: path, chunkHashes: chunkHashes, vectorClock: vc),
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
            print("[FileTransfer] ✅ [DEBUG] 所有块已存在，无需上传: 路径=\(path)")
            uploadedBytes = 0
            uploadSucceeded = true
            
        case .error(let errorMsg) where errorMsg.hasPrefix("缺失块:"):
            // 远程缺失某些块，需要上传这些块
            let missingHashesStr = errorMsg.replacingOccurrences(of: "缺失块: ", with: "")
            let missingHashes = missingHashesStr.split(separator: ",").map { String($0) }
            print("[FileTransfer] ⬆️ [DEBUG] 需要上传缺失块: 路径=\(path), 缺失块数=\(missingHashes.count)")
            
            // 并行上传缺失的块
            await withTaskGroup(of: (String, Int64)?.self) { group in
                for chunkHash in missingHashes {
                    group.addTask { [weak self] in
                        guard let self = self else { return nil }
                        guard let chunk = chunks.first(where: { $0.hash == chunkHash }) else {
                            print("[FileTransfer] ⚠️ [DEBUG] 找不到块数据: 路径=\(path), 块哈希=\(chunkHash.prefix(8))...")
                            return nil
                        }
                        
                        do {
                            let syncManager = await MainActor.run { self.syncManager }
                            guard let syncManager = syncManager else { return nil }
                            
                            print("[FileTransfer] ⬆️ [DEBUG] 上传块: 路径=\(path), 块哈希=\(chunkHash.prefix(8))..., 大小=\(chunk.data.count) bytes")
                            let putChunkRes: SyncResponse = try await syncManager.sendSyncRequest(
                                .putChunkData(syncID: folder.syncID, chunkHash: chunkHash, data: chunk.data),
                                to: peer,
                                peerID: peerID,
                                timeout: 180.0,
                                maxRetries: 3,
                                folder: folder
                            )
                            
                            if case .chunkAck = putChunkRes {
                                print("[FileTransfer] ✅ [DEBUG] 块上传成功: 路径=\(path), 块哈希=\(chunkHash.prefix(8))..., 大小=\(chunk.data.count) bytes")
                                return (chunkHash, Int64(chunk.data.count))
                            } else {
                                print("[FileTransfer] ❌ [DEBUG] 块上传失败: 路径=\(path), 块哈希=\(chunkHash.prefix(8))..., 响应=\(String(describing: putChunkRes))")
                            }
                        } catch {
                            print("[FileTransfer] ❌ [DEBUG] 上传块失败: 路径=\(path), 块哈希=\(chunkHash.prefix(8))..., 错误=\(error.localizedDescription)")
                        }
                        return nil
                    }
                }
                
                for await result in group {
                    if let (_, bytes) = result {
                        uploadedBytes += bytes
                        print("[FileTransfer] 📊 [DEBUG] 块上传进度: 路径=\(path), 已上传=\(uploadedBytes) bytes")
                    }
                }
            }
            print("[FileTransfer] ✅ [DEBUG] 所有缺失块上传完成: 路径=\(path), 总上传=\(uploadedBytes) bytes")
            
            // 上传完缺失的块后，再次发送 putFileChunks 确认
            print("[FileTransfer] 🔄 [DEBUG] 发送块列表确认: 路径=\(path)")
            let syncManagerForConfirm = await MainActor.run { self.syncManager }
            guard let syncManagerForConfirm = syncManagerForConfirm else {
                throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"])
            }
            let confirmRes: SyncResponse = try await syncManagerForConfirm.sendSyncRequest(
                .putFileChunks(syncID: folder.syncID, path: path, chunkHashes: chunkHashes, vectorClock: vc),
                to: peer,
                peerID: peerID,
                timeout: 90.0,
                maxRetries: 3,
                folder: folder
            )
            
            guard case .fileChunksAck = confirmRes else {
                // 确认失败，回退到全量上传（不保存 VC，因为上传失败）
                if case .error(let errorString) = confirmRes {
                    print("[FileTransfer] ⚠️ [DEBUG] 块级同步确认失败（错误响应），回退到全量上传: \(path) - \(errorString)")
                } else {
                    print("[FileTransfer] ⚠️ [DEBUG] 块级同步确认失败（响应格式错误），回退到全量上传: \(path) - 收到: \(String(describing: confirmRes))")
                }
                return try await uploadFileFull(
                    path: path,
                    localMeta: localMeta,
                    folder: folder,
                    peer: peer,
                    peerID: peerID,
                    myPeerID: myPeerID,
                    remoteEntries: remoteEntries,
                    shouldUpload: shouldUpload
                )
            }
            // 确认成功
            print("[FileTransfer] ✅ [DEBUG] 块列表确认成功: 路径=\(path)")
            uploadSucceeded = true
            
        default:
            // 其他错误，回退到全量上传（不保存 VC，因为上传失败）
            print("[FileTransfer] ⚠️ 块级同步失败，回退到全量上传: \(path)")
            return try await uploadFileFull(
                path: path,
                localMeta: localMeta,
                folder: folder,
                peer: peer,
                peerID: peerID,
                myPeerID: myPeerID,
                remoteEntries: remoteEntries,
                shouldUpload: shouldUpload
            )
        }
        
        // 只有在成功上传后才保存 Vector Clock（确保一致性）
        if uploadSucceeded {
            VectorClockManager.saveVectorClock(folderID: folder.id, syncID: folder.syncID, path: path, vc: vc)
            print("[FileTransfer] ✅ [DEBUG] 块级上传完成: 路径=\(path), 实际上传=\(uploadedBytes) bytes, 文件大小=\(chunks.reduce(0) { $0 + $1.data.count }) bytes, VC已保存")
        }
        
        let pathDir = (path as NSString).deletingLastPathComponent
        let folderName = pathDir.isEmpty ? nil : (pathDir as NSString).lastPathComponent
        
        return (uploadedBytes, SyncLog.SyncedFileInfo(
            path: path,
            fileName: fileName,
            folderName: folderName,
            size: Int64(chunks.reduce(0) { $0 + $1.data.count }),
            operation: .upload
        ))
    }
    
    /// 判断是否应该使用块级同步
    func shouldUseChunkSync(fileSize: Int64) -> Bool {
        return fileSize > chunkSyncThreshold
    }
}
