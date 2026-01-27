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
                
                // 获取文件状态存储
                let stateStore = await MainActor.run { syncManager.getFileStateStore(for: syncID) }
                
                // 构建统一的状态表示
                var fileStates: [String: FileState] = [:]
                
                // 添加存在的文件
                for (path, meta) in metadata {
                    fileStates[path] = .exists(meta)
                }
                
                // 添加删除记录
                let deletedPaths = stateStore.getDeletedPaths()
                for path in deletedPaths {
                    if let state = stateStore.getState(for: path),
                       case .deleted(let record) = state {
                        fileStates[path] = .deleted(record)
                    }
                }
                
                // 优先返回新的统一状态格式（filesV2）
                // 如果远程客户端支持 filesV2，使用新格式；否则使用旧格式（兼容性）
                // TODO: 可以通过协议协商来确定是否支持 filesV2
                // 目前先同时支持两种格式，优先使用新格式
                // 重要：即使 fileStates 为空，也要返回新格式，确保删除记录能传播
                // 如果只有删除记录没有文件，fileStates 不为空（包含删除记录）
                // 如果只有文件没有删除记录，fileStates 不为空（包含文件）
                // 如果两者都没有，fileStates 为空，但这种情况很少见
                if !fileStates.isEmpty || !deletedPaths.isEmpty {
                    // 如果有删除记录但没有文件，确保删除记录包含在 fileStates 中
                    if fileStates.isEmpty && !deletedPaths.isEmpty {
                        for path in deletedPaths {
                            if let state = stateStore.getState(for: path) {
                                fileStates[path] = state
                            }
                        }
                    }
                    return .filesV2(syncID: syncID, states: fileStates)
                }
                
                // 兼容旧格式（如果没有删除记录也没有文件）
                return .files(syncID: syncID, entries: metadata, deletedPaths: [])
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
        
        // 获取当前设备的 PeerID（用于创建删除记录）
        let peerID = await MainActor.run { syncManager.p2pNode.peerID ?? "" }
        
        // 使用原子性删除操作
        for rel in paths {
            await MainActor.run {
                syncManager.deleteFileAtomically(path: rel, syncID: syncID, peerID: peerID)
            }
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
