import Crypto
import Foundation

/// 同步请求处理扩展
/// 负责处理来自其他对等点的同步请求
extension SyncManager {
    /// 处理同步请求（统一处理函数）
    func handleSyncRequest(_ syncReq: SyncRequest) async throws -> SyncResponse {
        let startTime = Date()
        AppLogger.syncPrint("[SyncManager] 📥 Handling request: \(syncReq)")
        defer {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > 0.1 {
                AppLogger.syncPrint(
                    "[SyncManager] ✅ Handled request: \(syncReq.description) in \(String(format: "%.2f", elapsed))s"
                )
            }
        }
        switch syncReq {
        case .getMST(let syncID):
            guard let folder = await findFolder(by: syncID) else {
                return .error("Folder not found")
            }
            let (mst, _, _, _) = await self.calculateFullState(for: folder)
            return .mstRoot(syncID: syncID, rootHash: mst.rootHash ?? "empty")

        case .getFiles(let syncID):
            guard let folder = await findFolder(by: syncID) else {
                return .error("Folder not found")
            }
            let (_, metadata, _, _) = await self.calculateFullState(for: folder)
            return .files(syncID: syncID, entries: metadata)

        case .getFileData(let syncID, let relativePath):
            guard let folder = await findFolder(by: syncID) else {
                return .error("Folder not found")
            }
            let fileURL = folder.localPath.appendingPathComponent(relativePath)

            // 检查文件是否正在写入
            let fileManager = FileManager.default
            if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                let fileSize = attributes[.size] as? Int64,
                fileSize == 0
            {
                // 检查文件修改时间
                if let resourceValues = try? fileURL.resourceValues(forKeys: [
                    .contentModificationDateKey
                ]),
                    let mtime = resourceValues.contentModificationDate
                {
                    let timeSinceModification = Date().timeIntervalSince(mtime)
                    let stabilityDelay: TimeInterval = 3.0  // 文件大小稳定3秒后才认为写入完成
                    if timeSinceModification < stabilityDelay {
                        // 文件可能是0字节且刚被修改，可能还在写入，等待一下
                        AppLogger.syncPrint("[SyncManager] ⏳ 文件可能正在写入，等待稳定: \(relativePath)")
                        try? await Task.sleep(
                            nanoseconds: UInt64(stabilityDelay * 1_000_000_000))

                        // 再次检查文件大小
                        if let newAttributes = try? fileManager.attributesOfItem(
                            atPath: fileURL.path),
                            let newFileSize = newAttributes[.size] as? Int64,
                            newFileSize == 0
                        {
                            // 仍然是0字节，返回错误
                            return .error("文件可能正在写入中，请稍后重试")
                        }
                    }
                }
            }

            let data = try Data(contentsOf: fileURL)
            return .fileData(syncID: syncID, path: relativePath, data: data)

        case .putFileData(let syncID, let relativePath, let data, let vectorClock):
            guard let folder = await findFolder(by: syncID) else {
                return .error("Folder not found")
            }
            let fileURL = folder.localPath.appendingPathComponent(relativePath)
            let parentDir = fileURL.deletingLastPathComponent()
            let fileManager = FileManager.default

            // 远端写入，立即使缓存失效
            folderStatistics.invalidateCache(for: syncID)

            try? preparePathForWritingFile(
                fileURL: fileURL, baseDir: folder.localPath, fileManager: fileManager)
            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(
                    at: parentDir, withIntermediateDirectories: true)
            }

            guard fileManager.isWritableFile(atPath: parentDir.path) else {
                return .error("没有写入权限: \(parentDir.path)")
            }

            // 先合并 Vector Clock（在写入文件之前，确保 VC 逻辑正确）
            var mergedVC: VectorClock?
            if let vc = vectorClock {
                let localVC = VectorClockManager.getVectorClock(
                    folderID: folder.id, syncID: syncID, path: relativePath)
                mergedVC = VectorClockManager.mergeVectorClocks(localVC: localVC, remoteVC: vc)
            }

            // 标记同步写入冷却：即将落地远端写入，避免 FSEvents 回调把它当成本地修改并递增 VC
            self.markSyncCooldown(syncID: syncID, path: relativePath)

            // 写入文件
            try data.write(to: fileURL)

            // 文件写入成功后，保存 Vector Clock
            if let vc = mergedVC {
                VectorClockManager.saveVectorClock(
                    folderID: folder.id, syncID: syncID, path: relativePath, vc: vc)
            }

            return .putAck(syncID: syncID, path: relativePath)

        case .createDirectory(let syncID, let relativePath, let vectorClock):
            guard let folder = await findFolder(by: syncID) else {
                return .error("Folder not found")
            }
            let dirURL = folder.localPath.appendingPathComponent(relativePath)
            let fileManager = FileManager.default

            // 远端写入，立即使缓存失效
            folderStatistics.invalidateCache(for: syncID)

            // 标记同步写入冷却
            self.markSyncCooldown(syncID: syncID, path: relativePath)

            do {
                if !fileManager.fileExists(atPath: dirURL.path) {
                    try fileManager.createDirectory(
                        at: dirURL, withIntermediateDirectories: true, attributes: nil)
                }

                // 处理 Vector Clock
                if let vc = vectorClock {
                    let localVC = VectorClockManager.getVectorClock(
                        folderID: folder.id, syncID: syncID, path: relativePath)
                    let mergedVC = VectorClockManager.mergeVectorClocks(
                        localVC: localVC, remoteVC: vc)
                    VectorClockManager.saveVectorClock(
                        folderID: folder.id, syncID: syncID, path: relativePath, vc: mergedVC)
                }

                return .putAck(syncID: syncID, path: relativePath)
            } catch {
                return .error("无法创建目录: \(error.localizedDescription)")
            }

        case .deleteFiles(let syncID, let paths):
            guard (await findFolder(by: syncID)) != nil else {
                return .error("Folder not found")
            }
            let myPeerID = p2pNode.peerID?.b58String ?? ""
            // 批量删除时失效一次缓存
            folderStatistics.invalidateCache(for: syncID)
            for (rel, vc) in paths {
                deleteFileAtomically(path: rel, syncID: syncID, peerID: myPeerID, vectorClock: vc)
            }
            return .deleteAck(syncID: syncID)

        // 块级别增量同步请求
        case .getFileChunks(let syncID, let relativePath):
            return await handleGetFileChunks(syncID: syncID, path: relativePath)

        case .getChunkData(let syncID, let chunkHash):
            return await handleGetChunkData(syncID: syncID, chunkHash: chunkHash)

        case .putFileChunks(let syncID, let relativePath, let chunkHashes, let vectorClock):
            return await handlePutFileChunks(
                syncID: syncID, path: relativePath, chunkHashes: chunkHashes,
                vectorClock: vectorClock)

        case .putChunkData(let syncID, let chunkHash, let data):
            return await handlePutChunkData(syncID: syncID, chunkHash: chunkHash, data: data)
        }
    }

    // MARK: - 块级别增量同步处理

    /// 处理获取文件块列表请求
    func handleGetFileChunks(syncID: String, path: String) async -> SyncResponse {
        guard let folder = await findFolder(by: syncID) else {
            return .error("Folder not found")
        }

        let fileURL = folder.localPath.appendingPathComponent(path)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .error("File not found")
        }

        do {
            // 使用 FastCDC 切分文件为块
            let cdc = FastCDC(min: 4096, avg: 16384, max: 65536)
            let chunks = try cdc.chunk(fileURL: fileURL)
            let chunkHashes = chunks.map { $0.hash }

            // 保存块到本地存储（用于后续去重）
            for chunk in chunks {
                if !StorageManager.shared.hasBlock(hash: chunk.hash) {
                    try StorageManager.shared.saveBlock(hash: chunk.hash, data: chunk.data)
                }
            }

            return .fileChunks(syncID: syncID, path: path, chunkHashes: chunkHashes)
        } catch {
            return .error("无法切分文件: \(error.localizedDescription)")
        }
    }

    /// 处理获取块数据请求
    func handleGetChunkData(syncID: String, chunkHash: String) async -> SyncResponse {
        do {
            // 先从本地块存储获取
            if let data = try StorageManager.shared.getBlock(hash: chunkHash) {
                return .chunkData(syncID: syncID, chunkHash: chunkHash, data: data)
            }

            // 如果本地没有，尝试从文件重建（遍历所有文件查找包含该块的文件）
            guard let folder = await findFolder(by: syncID) else {
                return .error("Folder not found")
            }
            let fileManager = FileManager.default
            let enumerator = fileManager.enumerator(
                at: folder.localPath, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])

            if let enumerator = enumerator {
                // 先收集所有文件 URL，避免在异步上下文中使用枚举器
                var fileURLs: [URL] = []
                while let fileURL = enumerator.nextObject() as? URL {
                    fileURLs.append(fileURL)
                }

                // 然后处理收集到的文件
                for fileURL in fileURLs {
                    guard
                        let resourceValues = try? fileURL.resourceValues(forKeys: [
                            .isRegularFileKey
                        ]),
                        resourceValues.isRegularFile == true
                    else {
                        continue
                    }

                    do {
                        let cdc = FastCDC(min: 4096, avg: 16384, max: 65536)
                        let chunks = try cdc.chunk(fileURL: fileURL)

                        if let chunk = chunks.first(where: { $0.hash == chunkHash }) {
                            // 找到块，保存并返回
                            try StorageManager.shared.saveBlock(
                                hash: chunkHash, data: chunk.data)
                            return .chunkData(
                                syncID: syncID, chunkHash: chunkHash, data: chunk.data)
                        }
                    } catch {
                        continue
                    }
                }
            }
            return .error("块不存在: \(chunkHash)")
        } catch {
            return .error("获取块数据失败: \(error.localizedDescription)")
        }
    }

    /// 处理上传文件块列表请求
    func handlePutFileChunks(
        syncID: String, path: String, chunkHashes: [String], vectorClock: VectorClock?
    ) async -> SyncResponse {
        // 检查本地是否已有所有块
        let hasBlocks = StorageManager.shared.hasBlocks(hashes: chunkHashes)
        let missingHashes = chunkHashes.filter { !(hasBlocks[$0] ?? false) }

        if !missingHashes.isEmpty {
            // 返回缺失的块哈希列表，客户端需要上传这些块
            return .error("缺失块: \(missingHashes.joined(separator: ","))")
        }

        // 所有块都存在，重建文件
        guard let folder = await findFolder(by: syncID) else {
            return .error("Folder not found")
        }

        let fileURL = folder.localPath.appendingPathComponent(path)
        let parentDir = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default

        do {
            try? preparePathForWritingFile(
                fileURL: fileURL, baseDir: folder.localPath, fileManager: fileManager)
            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            guard fileManager.isWritableFile(atPath: parentDir.path) else {
                return .error("没有写入权限: \(parentDir.path)")
            }

            // 从块重建文件
            var fileData = Data()
            for chunkHash in chunkHashes {
                guard let chunkData = try StorageManager.shared.getBlock(hash: chunkHash) else {
                    return .error("块不存在: \(chunkHash)")
                }
                fileData.append(chunkData)
            }

            // 标记同步写入冷却：即将落地远端写入，避免 FSEvents 回调把它当成本地修改并递增 VC
            self.markSyncCooldown(syncID: syncID, path: path)

            // 写入文件
            try fileData.write(to: fileURL, options: [.atomic])

            // 更新 Vector Clock（使用 VectorClockManager）
            if let vc = vectorClock {
                let localVC = VectorClockManager.getVectorClock(
                    folderID: folder.id, syncID: syncID, path: path)
                let mergedVC = VectorClockManager.mergeVectorClocks(localVC: localVC, remoteVC: vc)
                VectorClockManager.saveVectorClock(
                    folderID: folder.id, syncID: syncID, path: path, vc: mergedVC)
            }

            return .fileChunksAck(syncID: syncID, path: path)
        } catch {
            return .error("重建文件失败: \(error.localizedDescription)")
        }
    }

    /// 处理上传块数据请求
    func handlePutChunkData(syncID: String, chunkHash: String, data: Data) async
        -> SyncResponse
    {
        do {
            // 验证块哈希
            let hash = SHA256.hash(data: data)
            let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()

            guard hashString == chunkHash else {
                return .error("块哈希不匹配: 期望 \(chunkHash)，实际 \(hashString)")
            }

            // 保存块
            try StorageManager.shared.saveBlock(hash: chunkHash, data: data)

            return .chunkAck(syncID: syncID, chunkHash: chunkHash)
        } catch {
            return .error("保存块失败: \(error.localizedDescription)")
        }
    }
}
