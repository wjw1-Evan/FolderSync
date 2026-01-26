import Foundation
import Crypto

/// 文件夹统计管理器
/// 负责文件数量、文件夹数量和总大小的统计计算
@MainActor
class FolderStatistics {
    weak var syncManager: SyncManager?
    weak var folderMonitor: FolderMonitor?
    
    // 统计更新锁：防止同一文件夹的并发统计更新导致竞态条件
    private var statisticsInProgress: Set<UUID> = []
    
    init(syncManager: SyncManager, folderMonitor: FolderMonitor?) {
        self.syncManager = syncManager
        self.folderMonitor = folderMonitor
    }
    
    /// 刷新文件夹的文件数量和文件夹数量统计
    func refreshFileCount(for folder: SyncFolder) {
        guard let syncManager = syncManager else { return }
        
        let folderID = folder.id
        
        // 检查是否已有统计正在进行，避免重复统计
        if statisticsInProgress.contains(folderID) {
            return
        }
        
        // 标记统计开始
        statisticsInProgress.insert(folderID)
        
        // 在后台任务中执行统计
        Task.detached { [weak self, weak syncManager] in
            guard let syncManager = syncManager else { return }
            
            // 获取最新的 folder 对象
            let currentFolder = await MainActor.run {
                return syncManager.folders.first(where: { $0.id == folderID })
            }
            
            guard let currentFolder = currentFolder else {
                _ = await MainActor.run { [weak self] in
                    self?.statisticsInProgress.remove(folderID)
                }
                return
            }
            
            // 使用 defer 确保统计锁被清理
            defer {
                Task { @MainActor in
                    self?.statisticsInProgress.remove(folderID)
                }
            }
            
            // 计算统计值
            let tempStatistics = await MainActor.run {
                return FolderStatistics(syncManager: syncManager, folderMonitor: nil)
            }
            let (_, metadata, folderCount, totalSize) = await tempStatistics.calculateFullState(for: currentFolder)
            
            // 更新统计值
            await MainActor.run {
                guard let index = syncManager.folders.firstIndex(where: { $0.id == folderID }) else {
                    return
                }
                
                var updatedFolder = syncManager.folders[index]
                updatedFolder.fileCount = metadata.count
                updatedFolder.folderCount = folderCount
                updatedFolder.totalSize = totalSize
                syncManager.folders[index] = updatedFolder
                syncManager.objectWillChange.send()
                
                // 保存到存储
                Task.detached {
                    try? StorageManager.shared.saveFolder(updatedFolder)
                }
            }
        }
    }
    
    /// 计算文件夹的完整状态（MST、元数据、文件夹数量、总大小）
    func calculateFullState(for folder: SyncFolder) async -> (MerkleSearchTree, [String: FileMetadata], folderCount: Int, totalSize: Int64) {
        guard let syncManager = syncManager else {
            return (MerkleSearchTree(), [:], 0, 0)
        }
        
        let url = folder.localPath
        let syncID = folder.syncID
        let mst = MerkleSearchTree()
        var metadata: [String: FileMetadata] = [:]
        var folderCount = 0
        var totalSize: Int64 = 0
        let fileManager = FileManager.default
        
        // 先收集所有文件路径（避免在枚举过程中处理）
        var filePaths: [(URL, String)] = []
        let resourceKeys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .contentModificationDateKey]
        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles])
        
        // 第一阶段：收集文件路径
        while let fileURL = enumerator?.nextObject() as? URL {
            do {
                guard fileManager.isReadableFile(atPath: fileURL.path) else {
                    continue
                }
                
                let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                var relativePath = fileURL.path.replacingOccurrences(of: url.path, with: "")
                if relativePath.hasPrefix("/") { relativePath.removeFirst() }
                
                if syncManager.isIgnored(relativePath, folder: folder) { continue }
                
                if resourceValues.isDirectory == true {
                    if !relativePath.isEmpty {
                        folderCount += 1
                    }
                } else {
                    // 文件路径
                    filePaths.append((fileURL, relativePath))
                }
            } catch {
                print("[FolderStatistics] ⚠️ 无法读取文件属性: \(fileURL.path) - \(error)")
                continue
            }
        }
        
        // 第二阶段：并行处理文件（使用任务组）
        let indexingBatchSize = 50
        let maxConcurrentFileProcessing = 4 // 最大并发文件处理数
        
        await withTaskGroup(of: (String, FileMetadata, Int64)?.self) { group in
            var activeTasks = 0
            var processedCount = 0
            
            for (fileURL, relativePath) in filePaths {
                // 控制并发数
                if activeTasks >= maxConcurrentFileProcessing {
                    // 等待一个任务完成
                    if let result = await group.next(), let (path, meta, size) = result {
                        metadata[path] = meta
                        mst.insert(key: path, value: meta.hash)
                        totalSize += size
                        activeTasks -= 1
                        processedCount += 1
                        if processedCount % indexingBatchSize == 0 {
                            await Task.yield()
                        }
                    }
                }
                
                activeTasks += 1
                group.addTask { [weak self] in
                    guard let self = self else { return nil }
                    
                    do {
                        let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                        let mtime = resourceValues.contentModificationDate ?? Date()
                        let vc = StorageManager.shared.getVectorClock(syncID: syncID, path: relativePath) ?? VectorClock()
                        
                        // 获取文件大小
                        var fileSize: Int64 = 0
                        if let fileAttributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                           let size = fileAttributes[.size] as? Int64 {
                            fileSize = size
                        }
                        
                        // 使用流式哈希计算（避免大文件一次性加载到内存）
                        let hash = try self.computeFileHash(fileURL: fileURL)
                        
                        return (relativePath, FileMetadata(hash: hash, mtime: mtime, vectorClock: vc), fileSize)
                    } catch {
                        print("[FolderStatistics] ⚠️ 无法处理文件（跳过）: \(fileURL.path) - \(error.localizedDescription)")
                        return nil
                    }
                }
            }
            
            // 处理剩余任务
            for await result in group {
                if let (path, meta, size) = result {
                    metadata[path] = meta
                    mst.insert(key: path, value: meta.hash)
                    totalSize += size
                }
            }
        }
        
        return (mst, metadata, folderCount, totalSize)
    }
    
    /// 流式计算文件哈希（避免一次性加载大文件到内存）
    nonisolated private func computeFileHash(fileURL: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }
        
        var hasher = SHA256()
        let bufferSize = 64 * 1024 // 64KB 缓冲区
        
        while true {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }
        
        let hash = hasher.finalize()
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
