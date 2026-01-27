import Foundation
import Crypto

/// P2P 消息处理器
/// 负责处理来自其他对等点的同步请求
@MainActor
class P2PHandlers {
    weak var syncManager: SyncManager?
    weak var folderStatistics: FolderStatistics?
    
    init(syncManager: SyncManager, folderStatistics: FolderStatistics) {
        self.syncManager = syncManager
        self.folderStatistics = folderStatistics
    }
    
    func setupP2PHandlers() {
        guard let syncManager = syncManager else { return }
        
        // 设置原生网络服务的消息处理器
        syncManager.p2pNode.nativeNetwork.messageHandler = { [weak self] request in
            guard let self = self else { return SyncResponse.error("Manager deallocated") }
            return try await self.handleSyncRequest(request)
        }
    }
    
    /// 处理同步请求（统一处理函数）
    private func handleSyncRequest(_ syncReq: SyncRequest) async throws -> SyncResponse {
        guard let syncManager = syncManager, let folderStatistics = folderStatistics else {
            return .error("Manager deallocated")
        }
        
        switch syncReq {
        case .getMST(let syncID):
            let folder = await MainActor.run { syncManager.folders.first(where: { $0.syncID == syncID }) }
            if let folder = folder {
                let (mst, _, _, _) = await folderStatistics.calculateFullState(for: folder)
                return .mstRoot(syncID: syncID, rootHash: mst.rootHash ?? "empty")
            }
            return .error("Folder not found")
            
        case .getFiles(let syncID):
            let folder = await MainActor.run { syncManager.folders.first(where: { $0.syncID == syncID }) }
            if let folder = folder {
                let (_, metadataRaw, _, _) = await folderStatistics.calculateFullState(for: folder)
                // 过滤掉冲突文件（冲突文件不应该被同步，避免无限循环）
                let metadata = ConflictFileFilter.filterConflictFiles(metadataRaw)
                // 获取本地的删除记录（tombstones），发送给远程客户端
                let deletedPaths = Array(syncManager.deletedPaths(for: syncID))
                return .files(syncID: syncID, entries: metadata, deletedPaths: deletedPaths)
            }
            return .error("Folder not found")
            
        case .getFileData(let syncID, let relativePath):
            return await handleGetFileData(syncID: syncID, relativePath: relativePath)
            
        case .putFileData(let syncID, let relativePath, let data, let vectorClock):
            return await handlePutFileData(syncID: syncID, relativePath: relativePath, data: data, vectorClock: vectorClock)
            
        case .deleteFiles(let syncID, let paths):
            return await handleDeleteFiles(syncID: syncID, paths: paths)
            
        case .getFileChunks(let syncID, let path):
            return await handleGetFileChunks(syncID: syncID, path: path)
            
        case .getChunkData(let syncID, let chunkHash):
            return await handleGetChunkData(syncID: syncID, chunkHash: chunkHash)
            
        case .putFileChunks(let syncID, let path, let chunkHashes, let vectorClock):
            return await handlePutFileChunks(syncID: syncID, path: path, chunkHashes: chunkHashes, vectorClock: vectorClock)
            
        case .putChunkData(let syncID, let chunkHash, let data):
            return await handlePutChunkData(syncID: syncID, chunkHash: chunkHash, data: data)
        }
    }
    
    private func handleGetFileData(syncID: String, relativePath: String) async -> SyncResponse {
        guard let syncManager = syncManager else {
            return .error("Manager deallocated")
        }
        
        let folder = await MainActor.run { syncManager.folders.first(where: { $0.syncID == syncID }) }
        guard let folder = folder else {
            return .error("Folder not found")
        }
        
        let fileURL = folder.localPath.appendingPathComponent(relativePath)
        
        // 检查文件是否正在写入
        let fileManager = FileManager.default
        if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
           let fileSize = attributes[.size] as? Int64,
           fileSize == 0 {
            // 检查文件修改时间
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
               let mtime = resourceValues.contentModificationDate {
                let timeSinceModification = Date().timeIntervalSince(mtime)
                if timeSinceModification < 3.0 {
                    // 文件可能是0字节且刚被修改，可能还在写入，等待一下
                    print("[P2PHandlers] ⏳ 文件可能正在写入，等待稳定: \(relativePath)")
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    
                    // 再次检查文件大小
                    if let newAttributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                       let newFileSize = newAttributes[.size] as? Int64,
                       newFileSize == 0 {
                        return .error("文件正在写入中，请稍后重试")
                    }
                }
            }
        }
        
        guard let data = try? Data(contentsOf: fileURL) else {
            return .error("无法读取文件")
        }
        
        return .fileData(syncID: syncID, path: relativePath, data: data)
    }
    
    private func handlePutFileData(syncID: String, relativePath: String, data: Data, vectorClock: VectorClock?) async -> SyncResponse {
        guard let syncManager = syncManager else {
            return .error("Manager deallocated")
        }
        
        let folder = await MainActor.run { syncManager.folders.first(where: { $0.syncID == syncID }) }
        guard let folder = folder else {
            return .error("Folder not found")
        }
        
        let fileURL = folder.localPath.appendingPathComponent(relativePath)
        let parentDir = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        
        if !fileManager.fileExists(atPath: parentDir.path) {
            try? fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        
        guard fileManager.isWritableFile(atPath: parentDir.path) else {
            return .error("没有写入权限: \(parentDir.path)")
        }
        
        do {
            // 先合并 Vector Clock（在写入文件之前，确保 VC 逻辑正确）
            var mergedVC: VectorClock?
            if let vc = vectorClock {
                let localVC = VectorClockManager.getVectorClock(syncID: syncID, path: relativePath)
                mergedVC = VectorClockManager.mergeVectorClocks(localVC: localVC, remoteVC: vc)
            }
            
            // 写入文件
            try data.write(to: fileURL)
            
            // 文件写入成功后，保存 Vector Clock
            if let vc = mergedVC {
                VectorClockManager.saveVectorClock(syncID: syncID, path: relativePath, vc: vc)
            }
            
            return .putAck(syncID: syncID, path: relativePath)
        } catch {
            return .error("写入文件失败: \(error.localizedDescription)")
        }
    }
    
    private func handleDeleteFiles(syncID: String, paths: [String]) async -> SyncResponse {
        guard let syncManager = syncManager else {
            return .error("Manager deallocated")
        }
        
        let folder = await MainActor.run { syncManager.folders.first(where: { $0.syncID == syncID }) }
        guard let folder = folder else {
            return .error("Folder not found")
        }
        
        let fileManager = FileManager.default
        
        for rel in paths {
            let fileURL = folder.localPath.appendingPathComponent(rel)
            // 如果文件存在，直接删除
            if fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.removeItem(at: fileURL)
            }
            // 删除 Vector Clock（使用 VectorClockManager）
            VectorClockManager.deleteVectorClock(syncID: syncID, path: rel)
        }
        return .deleteAck(syncID: syncID)
    }
    
    private func handleGetFileChunks(syncID: String, path: String) async -> SyncResponse {
        guard let syncManager = syncManager else {
            return .error("Manager deallocated")
        }
        
        let folder = await MainActor.run { syncManager.folders.first(where: { $0.syncID == syncID }) }
        guard let folder = folder else {
            return .error("Folder not found")
        }
        
        let fileURL = folder.localPath.appendingPathComponent(path)
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .error("文件不存在")
        }
        
        // 使用 FastCDC 分块
        do {
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
            return .error("无法读取文件: \(error.localizedDescription)")
        }
    }
    
    private func handleGetChunkData(syncID: String, chunkHash: String) async -> SyncResponse {
        // 尝试从块存储中获取
        if let data = try? StorageManager.shared.getBlock(hash: chunkHash) {
            return .chunkData(syncID: syncID, chunkHash: chunkHash, data: data)
        }
        
        // 如果块存储中没有，尝试从文件中重建（这不应该发生，但作为后备）
        return .error("块不存在: \(chunkHash)")
    }
    
    private func handlePutFileChunks(syncID: String, path: String, chunkHashes: [String], vectorClock: VectorClock?) async -> SyncResponse {
        guard let syncManager = syncManager else {
            return .error("Manager deallocated")
        }
        
        let folder = await MainActor.run { syncManager.folders.first(where: { $0.syncID == syncID }) }
        guard let folder = folder else {
            return .error("Folder not found")
        }
        
        // 检查本地是否已有所有块
        let hasBlocks = StorageManager.shared.hasBlocks(hashes: chunkHashes)
        let missingHashes = chunkHashes.filter { !(hasBlocks[$0] ?? false) }
        
        if !missingHashes.isEmpty {
            return .error("缺少块: \(missingHashes.count) 个")
        }
        
        // 从块重建文件
        let fileURL = folder.localPath.appendingPathComponent(path)
        let parentDir = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        
        if !fileManager.fileExists(atPath: parentDir.path) {
            try? fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        
        var fileData = Data()
        for chunkHash in chunkHashes {
            guard let chunkData = try? StorageManager.shared.getBlock(hash: chunkHash) else {
                return .error("块不存在: \(chunkHash)")
            }
            fileData.append(chunkData)
        }
        
        do {
            try fileData.write(to: fileURL, options: [.atomic])
            
            // 保存 Vector Clock（使用 VectorClockManager）
            if let vc = vectorClock {
                VectorClockManager.saveVectorClock(syncID: syncID, path: path, vc: vc)
            }
            
            return .chunkAck(syncID: syncID, chunkHash: chunkHashes.first ?? "")
        } catch {
            return .error("保存文件失败: \(error.localizedDescription)")
        }
    }
    
    private func handlePutChunkData(syncID: String, chunkHash: String, data: Data) async -> SyncResponse {
        do {
            try StorageManager.shared.saveBlock(hash: chunkHash, data: data)
            return .chunkAck(syncID: syncID, chunkHash: chunkHash)
        } catch {
            return .error("保存块失败: \(error.localizedDescription)")
        }
    }
}
