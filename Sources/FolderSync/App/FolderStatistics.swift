import Crypto
import Foundation

/// 文件夹统计管理器
/// 负责文件数量、文件夹数量和总大小的统计计算
@MainActor
class FolderStatistics {
    weak var syncManager: SyncManager?
    weak var folderMonitor: FolderMonitor?

    // 统计更新锁：防止同一文件夹的并发统计更新导致竞态条件
    private var statisticsInProgress: Set<UUID> = []

    // 完整状态缓存
    private struct StateCache {
        let mst: MerkleSearchTree
        let metadata: [String: FileMetadata]
        let folderCount: Int
        let totalSize: Int64
        let timestamp: Date
    }
    private var stateCache: [String: StateCache] = [:]  // syncID -> Cache
    private var calculationTasks:
        [String: Task<
            (MerkleSearchTree, [String: FileMetadata], folderCount: Int, totalSize: Int64), Never
        >] = [:]

    // UI 刷新防抖任务
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]

    init(syncManager: SyncManager, folderMonitor: FolderMonitor?) {
        self.syncManager = syncManager
        self.folderMonitor = folderMonitor
    }

    /// 刷新文件夹的文件数量和文件夹数量统计
    /// - Parameter changedPaths: 可选能够增量更新的文件路径集合。如果为 nil，则执行全量扫描。
    func refreshFileCount(for folder: SyncFolder, changedPaths: Set<String>? = nil) {
        guard let syncManager = syncManager else { return }

        let folderID = folder.id

        // 取消之前的刷新任务，实现防抖
        // 注意：如果是增量更新，我们也希望防抖，避免频繁的小更新
        refreshTasks[folderID]?.cancel()

        refreshTasks[folderID] = Task {
            // 收到变更后等待 1 秒
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return  // 被取消了
            }

            if Task.isCancelled { return }

            // 计算统计值
            var result: (MerkleSearchTree, [String: FileMetadata], Int, Int64)

            if let paths = changedPaths {
                // 尝试增量更新
                if let incrementalResult = await self.applyIncrementalUpdates(
                    for: folder, changedPaths: paths)
                {
                    result = incrementalResult
                } else {
                    // 增量更新失败（可能缓存不存在），回退到全量计算
                    result = await self.calculateFullState(for: folder)
                }
            } else {
                // 全量计算
                result = await self.calculateFullState(for: folder)
            }

            if Task.isCancelled { return }

            let (_, metadata, folderCount, totalSize) = result

            // 更新 UI
            guard let index = syncManager.folders.firstIndex(where: { $0.id == folderID })
            else {
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

            self.refreshTasks.removeValue(forKey: folderID)
        }
    }

    /// 计算文件夹的完整状态（MST、元数据、文件夹数量、总大小）
    func calculateFullState(for folder: SyncFolder) async -> (
        MerkleSearchTree, [String: FileMetadata], folderCount: Int, totalSize: Int64
    ) {
        let syncID = folder.syncID

        // 1. 检查缓存（5秒内认为有效，避免瞬时重复计算）
        if let cache = stateCache[syncID], Date().timeIntervalSince(cache.timestamp) < 5.0 {
            return (cache.mst, cache.metadata, cache.folderCount, cache.totalSize)
        }

        // 2. 检查是否有任务正在进行，如果有则复用（聚合并发请求）
        if let existingTask = calculationTasks[syncID] {
            return await existingTask.value
        }

        // 3. 创建新任务
        let task = Task {
            let result = await performFullStateCalculation(for: folder)
            // 异步回到主线程更新缓存
            await MainActor.run {
                self.stateCache[syncID] = StateCache(
                    mst: result.0,
                    metadata: result.1,
                    folderCount: result.2,
                    totalSize: result.3,
                    timestamp: Date()
                )
                self.calculationTasks.removeValue(forKey: syncID)
            }
            return result
        }

        calculationTasks[syncID] = task
        return await task.value
    }

    /// 应用增量更新
    /// 如果缓存存在，则只更新变更的文件，并重新计算统计信息
    /// - Returns: 更新后的状态，如果无法增量更新（无缓存）则返回 nil
    private func applyIncrementalUpdates(for folder: SyncFolder, changedPaths: Set<String>) async
        -> (
            MerkleSearchTree, [String: FileMetadata], folderCount: Int, totalSize: Int64
        )?
    {
        let syncID = folder.syncID
        guard let syncManager = syncManager else { return nil }

        // 1. 获取初始状态（从缓存或持久化存储）
        var cache: StateCache

        if let existingCache = stateCache[syncID] {
            cache = existingCache
        } else if let persistedMetadata = syncManager.lastKnownMetadata[syncID] {
            // 从持久化元数据恢复
            let mst = MerkleSearchTree()
            var totalSize: Int64 = 0
            var folderCount = 0

            for (path, meta) in persistedMetadata {
                mst.insert(key: path, value: meta.hash)
                if !meta.isDirectory {
                    totalSize += meta.size
                } else {
                    folderCount += 1
                }
            }

            cache = StateCache(
                mst: mst,
                metadata: persistedMetadata,
                folderCount: folderCount,
                totalSize: totalSize,
                timestamp: Date()
            )
        } else {
            return nil
        }

        // 复制一份元数据进行修改
        var updatedMetadata = cache.metadata
        var updatedFolderCount = cache.folderCount
        var updatedTotalSize = cache.totalSize
        // 2. 处理每个变更路径
        let fileManager = FileManager.default
        let url = folder.localPath.resolvingSymlinksInPath().standardizedFileURL

        // 2. 处理每个变更路径
        for rawPath in changedPaths {
            if rawPath.isEmpty { continue }
            let relativePath = rawPath.precomposedStringWithCanonicalMapping
            if syncManager.isIgnored(relativePath, folder: folder) { continue }

            let fileURL = url.appendingPathComponent(relativePath)
            let exists = fileManager.fileExists(atPath: fileURL.path)

            // 移除旧的元数据
            if let oldMeta = updatedMetadata[relativePath] {
                if !oldMeta.isDirectory {
                    updatedTotalSize -= oldMeta.size
                } else {
                    updatedFolderCount -= 1
                }
                updatedMetadata.removeValue(forKey: relativePath)
            }

            // 如果文件已被删除，循环继续（已在上面移除）
            if !exists { continue }

            // 如果是新增或修改，计算新元数据
            do {
                if !ConflictFileFilter.isConflictFile(relativePath) {
                    var isDirectory: ObjCBool = false
                    _ = fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)

                    let resourceValues = try fileURL.resourceValues(forKeys: [
                        .contentModificationDateKey, .creationDateKey,
                    ])
                    let mtime = resourceValues.contentModificationDate ?? Date()
                    let creationDate = resourceValues.creationDate

                    let vc =
                        VectorClockManager.getVectorClock(
                            folderID: folder.id, syncID: syncID, path: relativePath)
                        ?? VectorClock()

                    if isDirectory.boolValue {
                        updatedFolderCount += 1
                        let dirMeta = FileMetadata(
                            hash: "DIRECTORY",
                            mtime: mtime,
                            size: 0,
                            creationDate: creationDate,
                            vectorClock: vc,
                            isDirectory: true
                        )
                        updatedMetadata[relativePath] = dirMeta
                    } else {
                        // 文件
                        let fileSize =
                            (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size]
                                as? Int64) ?? 0

                        // 计算哈希 (这里可能会有 I/O，但只针对变更文件)
                        let hash = try await syncManager.computeFileHash(fileURL: fileURL)

                        updatedTotalSize += fileSize

                        let fileMeta = FileMetadata(
                            hash: hash,
                            mtime: mtime,
                            size: fileSize,
                            creationDate: creationDate,
                            vectorClock: vc
                        )
                        updatedMetadata[relativePath] = fileMeta
                    }
                }
            } catch {
                AppLogger.syncPrint("[FolderStatistics] ⚠️ 增量更新文件失败: \(relativePath) - \(error)")
            }
        }

        // 3. 重建 MST (基于内存 metadata，无磁盘 I/O)
        let newMST = MerkleSearchTree()
        for (path, meta) in updatedMetadata {
            newMST.insert(key: path, value: meta.hash)
        }

        // 4. 更新缓存
        await MainActor.run {
            self.stateCache[syncID] = StateCache(
                mst: newMST,
                metadata: updatedMetadata,
                folderCount: updatedFolderCount,
                totalSize: updatedTotalSize,
                timestamp: Date()
            )
        }

        AppLogger.syncPrint(
            "[FolderStatistics] ✨ 增量更新完成: \(folder.localPath.lastPathComponent), 变更数: \(changedPaths.count)"
        )

        return (newMST, updatedMetadata, updatedFolderCount, updatedTotalSize)
    }

    /// 使缓存失效
    func invalidateCache(for syncID: String) {
        stateCache.removeValue(forKey: syncID)
    }

    /// 实际执行计算逻辑的方法
    private func performFullStateCalculation(for folder: SyncFolder) async -> (
        MerkleSearchTree, [String: FileMetadata], folderCount: Int, totalSize: Int64
    ) {
        guard let syncManager = syncManager else {
            return (MerkleSearchTree(), [:], 0, 0)
        }

        // 统一规范化路径，避免 `/var` 与 `/private/var` 混用导致相对路径带上 `private/` 前缀
        let url = folder.localPath.resolvingSymlinksInPath().standardizedFileURL
        let syncID = folder.syncID
        let mst = MerkleSearchTree()
        var metadata: [String: FileMetadata] = [:]
        var folderCount = 0
        var totalSize: Int64 = 0
        let fileManager = FileManager.default

        // 优化：获取上个版本的元数据缓存，用于快速指纹比对
        // 这里可以直接使用 syncManager 的缓存，它是持久化的结果
        let lastMetadata = syncManager.lastKnownMetadata[syncID] ?? [:]

        // 先收集所有文件路径（避免在枚举过程中处理）
        var filePaths: [(URL, String)] = []
        let resourceKeys: [URLResourceKey] = [
            .nameKey, .isDirectoryKey, .contentModificationDateKey, .creationDateKey,
        ]
        let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles])
        let basePath = url.path

        // 第一阶段：收集文件路径
        while let fileURL = enumerator?.nextObject() as? URL {
            do {
                let canonicalFileURL = fileURL.resolvingSymlinksInPath().standardizedFileURL

                // 获取相对路径
                // 通过标准化后的绝对路径计算相对路径，避免 replace 不匹配导致的 `private/...`
                guard canonicalFileURL.path.hasPrefix(basePath) else { continue }
                var relativePath = String(canonicalFileURL.path.dropFirst(basePath.count))
                if relativePath.hasPrefix("/") { relativePath.removeFirst() }

                // 统一规范化为 NFC 格式
                relativePath = relativePath.precomposedStringWithCanonicalMapping

                if relativePath.isEmpty { continue }

                // 检查是否为目录
                var isDirectory: ObjCBool = false
                guard
                    fileManager.fileExists(atPath: canonicalFileURL.path, isDirectory: &isDirectory)
                else {
                    continue
                }

                if syncManager.isIgnored(relativePath, folder: folder) { continue }

                if isDirectory.boolValue {
                    // 目录：统计数量并添加到元数据
                    folderCount += 1

                    // 获取目录属性 (mtime)
                    let resourceValues = try canonicalFileURL.resourceValues(
                        forKeys: Set(resourceKeys))
                    let mtime = resourceValues.contentModificationDate ?? Date()
                    let creationDate = resourceValues.creationDate
                    let vc =
                        VectorClockManager.getVectorClock(
                            folderID: folder.id, syncID: syncID, path: relativePath)
                        ?? VectorClock()

                    // 创建目录元数据
                    let dirMeta = FileMetadata(
                        hash: "DIRECTORY",  // 固定哈希，支持重命名检测
                        mtime: mtime,
                        size: 0,
                        creationDate: creationDate,
                        vectorClock: vc,
                        isDirectory: true
                    )

                    metadata[relativePath] = dirMeta
                    mst.insert(key: relativePath, value: dirMeta.hash)
                    continue
                }

                guard fileManager.isReadableFile(atPath: canonicalFileURL.path) else {
                    continue
                }

                // 文件路径：排除冲突文件（冲突文件不应该被同步）
                if !ConflictFileFilter.isConflictFile(relativePath) {
                    filePaths.append((canonicalFileURL, relativePath))
                }
            } catch {
                AppLogger.syncPrint("[FolderStatistics] ⚠️ 无法读取文件属性: \(fileURL.path) - \(error)")
                continue
            }
        }

        // 第二阶段：并行处理文件（使用任务组）
        let indexingBatchSize = 50
        let maxConcurrentFileProcessing = 8  // 与传输并发数一致，提升索引吞吐

        await withTaskGroup(of: (String, FileMetadata, Int64)?.self) { group in
            var activeTasks = 0
            var processedCount = 0

            for (fileURL, relativePath) in filePaths {
                // 控制并发数：等待一个槽位空出（每消费一个完成信号即释放槽位，无论结果是否有效）
                if activeTasks >= maxConcurrentFileProcessing {
                    let result = await group.next()
                    activeTasks -= 1
                    if let unpacked = result, let (path, meta, size) = unpacked {
                        metadata[path] = meta
                        mst.insert(key: path, value: meta.hash)
                        totalSize += size
                        processedCount += 1
                        if processedCount % indexingBatchSize == 0 {
                            await Task.yield()
                        }
                    }
                }

                activeTasks += 1
                group.addTask {
                    do {
                        let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                        let mtime = resourceValues.contentModificationDate ?? Date()
                        let creationDate = resourceValues.creationDate
                        let vc =
                            VectorClockManager.getVectorClock(
                                folderID: folder.id, syncID: syncID, path: relativePath)
                            ?? VectorClock()

                        // 获取文件大小
                        var fileSize: Int64 = 0
                        if let fileAttributes = try? fileManager.attributesOfItem(
                            atPath: fileURL.path),
                            let size = fileAttributes[.size] as? Int64
                        {
                            fileSize = size
                        }

                        // 增量哈希优化：检查文件元数据的指纹（mtime）是否变化
                        // 我们在这里不仅比较 mtime，还可以进一步确保 vectorClock 的一致性
                        if let cached = lastMetadata[relativePath],
                            abs(cached.mtime.timeIntervalSince(mtime)) < 0.001
                        {
                            // 指纹匹配，复用已有的哈希值，跳过昂贵的 IO 计算
                            return (
                                relativePath,
                                FileMetadata(
                                    hash: cached.hash, mtime: mtime, size: fileSize,
                                    creationDate: creationDate,
                                    vectorClock: vc),
                                fileSize
                            )
                        }

                        // 使用流式哈希计算（避免大文件一次性加载到内存）
                        let hash = try await syncManager.computeFileHash(fileURL: fileURL)

                        return (
                            relativePath,
                            FileMetadata(
                                hash: hash, mtime: mtime, size: fileSize,
                                creationDate: creationDate,
                                vectorClock: vc),
                            fileSize
                        )
                    } catch {
                        AppLogger.syncPrint(
                            "[FolderStatistics] ⚠️ 无法处理文件（跳过）: \(fileURL.path) - \(error.localizedDescription)"
                        )
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

                    processedCount += 1
                    if processedCount % indexingBatchSize == 0 {
                        await Task.yield()
                    }
                }
            }
        }

        return (mst, metadata, folderCount, totalSize)
    }

    /// 已删除：computeFileHash 移到了 SyncManagerUtilities.swift，避免重复定义
    /// 并且现在的实现是异步的。

}
