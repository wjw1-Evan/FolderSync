import Foundation
import Crypto

/// 文件传输管理器
/// 负责文件的上传和下载操作
@MainActor
class FileTransfer {
    weak var syncManager: SyncManager?
    
    private let chunkSyncThreshold: Int64 = 1 * 1024 * 1024 // 1MB，超过此大小的文件使用块级增量同步
    private let maxConcurrentTransfers = 3 // 最大并发传输数（上传/下载）
    
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
            print("[FileTransfer] ❌ \(errorMsg) - 文件: \(path)")
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        let localURL = folder.localPath.appendingPathComponent(path)
        let parentDir = localURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        
        // 检查并创建父目录
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        
        // 检查写入权限
        guard fileManager.isWritableFile(atPath: parentDir.path) else {
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "没有写入权限: \(parentDir.path)"])
        }
        
        try data.write(to: localURL)
        
        // 合并 Vector Clock（使用 VectorClockManager）
        let localVC = localMetadata[path]?.vectorClock
        let remoteVC = remoteMeta.vectorClock
        let mergedVC = VectorClockManager.mergeVectorClocks(localVC: localVC, remoteVC: remoteVC)
        VectorClockManager.saveVectorClock(syncID: folder.syncID, path: path, vc: mergedVC)
        
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
                print("[FileTransfer] ⚠️ 块级同步失败（错误响应），回退到全量下载: \(path) - \(errorString)")
            } else {
                print("[FileTransfer] ⚠️ 块级同步失败（响应格式错误），回退到全量下载: \(path) - 收到: \(String(describing: chunksRes))")
            }
            return try await downloadFileFull(path: path, remoteMeta: remoteMeta, folder: folder, peer: peer, peerID: peerID, localMetadata: localMetadata)
        }
        
        // 2. 检查本地已有的块
        let hasBlocks = StorageManager.shared.hasBlocks(hashes: remoteChunkHashes)
        let missingHashes = remoteChunkHashes.filter { !(hasBlocks[$0] ?? false) }
        
        // 3. 下载缺失的块（并行下载）
        var downloadedBytes: Int64 = 0
        if !missingHashes.isEmpty {
            await withTaskGroup(of: (String, Data)?.self) { group in
                for chunkHash in missingHashes {
                    group.addTask { [weak self] in
                        guard let self = self else { return nil }
                        do {
                            let syncManager = await MainActor.run { self.syncManager }
                            guard let syncManager = syncManager else { return nil }
                            
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
                                    print("[FileTransfer] ⚠️ 获取块数据失败: \(chunkHash) - \(errorString)")
                                } else {
                                    print("[FileTransfer] ⚠️ 获取块数据响应格式错误: \(chunkHash) - 收到: \(String(describing: chunkRes))")
                                }
                                return nil
                            }
                            
                            // 保存块
                            try StorageManager.shared.saveBlock(hash: chunkHash, data: data)
                            return (chunkHash, data)
                        } catch {
                            print("[FileTransfer] ⚠️ 下载块失败: \(chunkHash.prefix(8))... - \(error.localizedDescription)")
                            return nil
                        }
                    }
                }
                
                for await result in group {
                    if let (_, data) = result {
                        downloadedBytes += Int64(data.count)
                    }
                }
            }
        }
        
        // 4. 从块重建文件
        let localURL = folder.localPath.appendingPathComponent(path)
        let parentDir = localURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        
        if !fileManager.fileExists(atPath: parentDir.path) {
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
        
        try fileData.write(to: localURL, options: [.atomic])
        
        // 合并 Vector Clock（使用 VectorClockManager）
        let localVC = localMetadata[path]?.vectorClock
        let remoteVC = remoteMeta.vectorClock
        let mergedVC = VectorClockManager.mergeVectorClocks(localVC: localVC, remoteVC: remoteVC)
        VectorClockManager.saveVectorClock(syncID: folder.syncID, path: path, vc: mergedVC)
        
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
        
        // 检查文件是否存在和可读
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "文件不存在: \(path)"])
        }
        
        guard fileManager.isReadableFile(atPath: fileURL.path) else {
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "文件无读取权限: \(path)"])
        }
        
        // 再次检查是否需要上传（可能在准备上传时文件已被同步）
        if let remoteMeta = remoteEntries[path], !shouldUpload(localMeta, remoteMeta, path) {
            throw NSError(domain: "FileTransfer", code: -2, userInfo: [NSLocalizedDescriptionKey: "文件已同步，跳过上传"])
        }
        
        let data = try Data(contentsOf: fileURL)
        
        // 准备 Vector Clock（在发送前准备，但只在成功后保存）
        // 注意：Vector Clock 应该在文件实际修改时更新，这里只是确保有最新的 VC
        let currentVC = VectorClockManager.getVectorClock(syncID: folder.syncID, path: path) ?? VectorClock()
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
            print("[FileTransfer] ❌ \(errorMsg) - 文件: \(path)")
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        // 发送成功后才保存 Vector Clock（确保一致性）
        VectorClockManager.saveVectorClock(syncID: folder.syncID, path: path, vc: vc)
        
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
        
        // 检查文件是否存在和可读
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "文件不存在: \(path)"])
        }
        
        guard fileManager.isReadableFile(atPath: fileURL.path) else {
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "文件无读取权限: \(path)"])
        }
        
        // 再次检查是否需要上传
        if let remoteMeta = remoteEntries[path], !shouldUpload(localMeta, remoteMeta, path) {
            throw NSError(domain: "FileTransfer", code: -2, userInfo: [NSLocalizedDescriptionKey: "文件已同步，跳过上传"])
        }
        
        // 1. 使用 FastCDC 切分文件为块
        let cdc = FastCDC(min: 4096, avg: 16384, max: 65536)
        let chunks = try cdc.chunk(fileURL: fileURL)
        let chunkHashes = chunks.map { $0.hash }
        
        // 2. 保存块到本地存储（用于后续去重）
        for chunk in chunks {
            if !StorageManager.shared.hasBlock(hash: chunk.hash) {
                try StorageManager.shared.saveBlock(hash: chunk.hash, data: chunk.data)
            }
        }
        
        // 3. 准备 Vector Clock（在发送前准备，但只在成功后保存）
        // 注意：Vector Clock 应该在文件实际修改时更新，这里只是确保有最新的 VC
        let currentVC = VectorClockManager.getVectorClock(syncID: folder.syncID, path: path) ?? VectorClock()
        var vc = currentVC
        vc.increment(for: myPeerID)
        
        // 4. 上传块列表（携带更新后的 VC）
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
            uploadedBytes = 0
            uploadSucceeded = true
            
        case .error(let errorMsg) where errorMsg.hasPrefix("缺失块:"):
            // 远程缺失某些块，需要上传这些块
            let missingHashesStr = errorMsg.replacingOccurrences(of: "缺失块: ", with: "")
            let missingHashes = missingHashesStr.split(separator: ",").map { String($0) }
            
            // 并行上传缺失的块
            await withTaskGroup(of: (String, Int64)?.self) { group in
                for chunkHash in missingHashes {
                    group.addTask { [weak self] in
                        guard let self = self else { return nil }
                        guard let chunk = chunks.first(where: { $0.hash == chunkHash }) else {
                            return nil
                        }
                        
                        do {
                            let syncManager = await MainActor.run { self.syncManager }
                            guard let syncManager = syncManager else { return nil }
                            
                            let putChunkRes: SyncResponse = try await syncManager.sendSyncRequest(
                                .putChunkData(syncID: folder.syncID, chunkHash: chunkHash, data: chunk.data),
                                to: peer,
                                peerID: peerID,
                                timeout: 180.0,
                                maxRetries: 3,
                                folder: folder
                            )
                            
                            if case .chunkAck = putChunkRes {
                                return (chunkHash, Int64(chunk.data.count))
                            }
                        } catch {
                            print("[FileTransfer] ⚠️ 上传块失败: \(chunkHash) - \(error.localizedDescription)")
                        }
                        return nil
                    }
                }
                
                for await result in group {
                    if let (_, bytes) = result {
                        uploadedBytes += bytes
                    }
                }
            }
            
            // 上传完缺失的块后，再次发送 putFileChunks 确认
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
                    print("[FileTransfer] ⚠️ 块级同步确认失败（错误响应），回退到全量上传: \(path) - \(errorString)")
                } else {
                    print("[FileTransfer] ⚠️ 块级同步确认失败（响应格式错误），回退到全量上传: \(path) - 收到: \(String(describing: confirmRes))")
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
            VectorClockManager.saveVectorClock(syncID: folder.syncID, path: path, vc: vc)
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
