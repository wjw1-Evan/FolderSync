import CoreServices
import Foundation

/// 本地变更记录扩展
/// 负责记录和处理本地文件系统的变更事件
extension SyncManager {
    func recordLocalChange(
        for folder: SyncFolder, absolutePath: String, flags: FSEventStreamEventFlags,
        precomputedHash: String? = nil, saveToDisk: Bool = true
    ) async -> (LocalChange?, VectorClock?) {
        var updatedVC: VectorClock?
        let basePath = folder.localPath.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalAbsolutePath = URL(fileURLWithPath: absolutePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard canonicalAbsolutePath.hasPrefix(basePath) else { return (nil, nil) }

        var relativePath = String(canonicalAbsolutePath.dropFirst(basePath.count))
        if relativePath.hasPrefix("/") { relativePath.removeFirst() }
        relativePath = relativePath.precomposedStringWithCanonicalMapping
        if relativePath.isEmpty { relativePath = "." }

        folderStatistics.invalidateCache(for: folder.syncID)

        let cooldownKey = "\(folder.syncID):\(relativePath)"
        if let lastWriteTime = syncWriteCooldown[cooldownKey],
            Date().timeIntervalSince(lastWriteTime) < syncCooldownDuration
        {
            return (nil, nil)
        }

        if relativePath == "." {
            return (nil, nil)
        }

        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: canonicalAbsolutePath)

        // 目录处理：清除同步删除状态
        if exists {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: canonicalAbsolutePath, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                let stateStore = getFileStateStore(for: folder.syncID)
                if stateStore.getState(for: relativePath)?.isDeleted == true {
                    stateStore.removeState(path: relativePath)
                    lastKnownLocalPaths[folder.syncID]?.insert(relativePath)
                    var dp = deletedPaths(for: folder.syncID)
                    dp.remove(relativePath)
                    updateDeletedPaths(dp, for: folder.syncID)
                }
            }
        }

        if ConflictFileFilter.isConflictFile(relativePath)
            || isIgnored(relativePath, folder: folder)
        {
            return (nil, nil)
        }

        // 处理过期重命名
        let now = Date()
        let currentFolderPrefix = "\(folder.syncID):"
        pendingRenames = pendingRenames.filter { key, value in
            guard key.hasPrefix(currentFolderPrefix) else { return true }
            return now.timeIntervalSince(value.timestamp) <= renameDetectionWindow
        }

        var cachedHash: String? = precomputedHash
        let getHash = { () async throws -> String in
            if let h = cachedHash { return h }
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: canonicalAbsolutePath, isDirectory: &isDir),
                isDir.boolValue
            {
                cachedHash = "DIRECTORY"
                return "DIRECTORY"
            }
            let h = try await self.computeFileHash(
                fileURL: URL(fileURLWithPath: canonicalAbsolutePath))
            cachedHash = h
            return h
        }

        let changeKey = "\(folder.syncID):\(relativePath)"
        let isKnownPath = lastKnownLocalPaths[folder.syncID]?.contains(relativePath) ?? false

        // 去重逻辑
        if let lastProcessed = recentChanges[changeKey],
            now.timeIntervalSince(lastProcessed) < changeDeduplicationWindow
        {
            if exists != isKnownPath {
                // 状态转移，不跳过
            } else if exists, let knownMeta = lastKnownMetadata[folder.syncID]?[relativePath] {
                let attrs = try? fileManager.attributesOfItem(atPath: canonicalAbsolutePath)
                let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
                if abs(knownMeta.mtime.timeIntervalSince(mtime)) < 0.001 {
                    return (nil, nil)
                }
                let currentHash = (try? await getHash()) ?? knownMeta.hash
                if currentHash == knownMeta.hash {
                    return (nil, nil)
                }
            } else {
                return (nil, nil)
            }
        }
        recentChanges[changeKey] = now

        var size: Int64?
        if exists, let attrs = try? fileManager.attributesOfItem(atPath: absolutePath),
            let s = attrs[.size] as? Int64
        {
            size = s
        }

        let hasRemovedFlag =
            (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0)
        let hasCreatedFlag =
            (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0)
        let hasModifiedFlag =
            (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0)
        let hasRenamedFlag =
            (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0)

        if !hasRemovedFlag && !hasCreatedFlag && !hasModifiedFlag && !hasRenamedFlag {
            return (nil, nil)
        }

        var changeType: LocalChange.ChangeType = .modified
        var matchedRenameOldPath: String? = nil

        if !exists {
            if isKnownPath || hasRemovedFlag || hasRenamedFlag {
                // 检查是否可能为重命名（旧路径）
                if isKnownPath && hasRenamedFlag && !hasRemovedFlag {
                    if let knownMeta = lastKnownMetadata[folder.syncID]?[relativePath] {
                        pendingRenames[changeKey] = (hash: knownMeta.hash, timestamp: now)
                        schedulePendingRenameTimeout(
                            folder: folder, relativePath: relativePath, pendingKey: changeKey,
                            scheduledAt: now)
                        AppLogger.syncPrint("[recordLocalChange] 🔄 记录重命名旧路径，等待新路径: \(relativePath)")
                        return (nil, nil)
                    }
                }
                changeType = .deleted
            } else {
                return (nil, nil)
            }
        } else if isKnownPath {
            // 已存在路径的修改检查
            if let knownMeta = lastKnownMetadata[folder.syncID]?[relativePath] {
                do {
                    let currentHash = try await getHash()
                    if currentHash == knownMeta.hash {
                        let attrs = try? fileManager.attributesOfItem(atPath: canonicalAbsolutePath)
                        let currentMtime = (attrs?[.modificationDate] as? Date) ?? Date()
                        if abs(knownMeta.mtime.timeIntervalSince(currentMtime)) < 0.001 {
                            return (nil, nil)
                        }
                    }
                    changeType = .modified
                } catch {
                    if hasModifiedFlag { changeType = .modified } else { return (nil, nil) }
                }
            } else {
                return (nil, nil)
            }
        } else {
            // 新路径，检查是否为重命名（新路径）
            if hasRemovedFlag { return (nil, nil) }

            do {
                let currentHash = try await getHash()
                for (pendingKey, pendingInfo) in pendingRenames {
                    let keyParts = pendingKey.split(separator: ":", maxSplits: 1)
                    if keyParts.count == 2, keyParts[0] == folder.syncID {
                        let oldPath = String(keyParts[1])
                        if pendingInfo.hash == currentHash
                            && (hasRenamedFlag
                                || now.timeIntervalSince(pendingInfo.timestamp)
                                    <= renameDetectionWindow)
                        {
                            matchedRenameOldPath = oldPath
                            pendingRenames.removeValue(forKey: pendingKey)
                            break
                        }
                    }
                }

                if matchedRenameOldPath == nil && hasRenamedFlag {
                    if let (oldPath, _) = lastKnownMetadata[folder.syncID]?.first(where: {
                        $0.value.hash == currentHash
                    }) {
                        matchedRenameOldPath = oldPath
                    }
                }
            } catch {
                AppLogger.syncPrint("[recordLocalChange] ⚠️ 哈希计算失败: \(error)")
            }

            if matchedRenameOldPath != nil {
                changeType = .renamed
            } else if hasCreatedFlag {
                changeType = .created
            } else if hasModifiedFlag {
                changeType = .modified
            } else {
                return (nil, nil)
            }
        }

        // 统一 Vector Clock 处理
        if let myPeerID = p2pNode.peerID?.b58String, !myPeerID.isEmpty {
            if changeType == .renamed, let oldPath = matchedRenameOldPath {
                _ = VectorClockManager.migrateVectorClock(
                    folderID: folder.id, syncID: folder.syncID, oldPath: oldPath,
                    newPath: relativePath)
            }
            let vc = VectorClockManager.updateForLocalChange(
                folderID: folder.id, syncID: folder.syncID, path: relativePath, peerID: myPeerID)
            if saveToDisk {
                VectorClockManager.saveVectorClock(
                    folderID: folder.id, syncID: folder.syncID, path: relativePath, vc: vc)
            }
            updatedVC = vc
        }

        let change = LocalChange(
            folderID: folder.id,
            path: relativePath,
            changeType: changeType,
            size: size,
            timestamp: Date(),
            sequence: nil
        )

        // 立即更新已知路径列表和元数据，避免后续重复事件
        if changeType == .created || changeType == .renamed {
            // 如果是重命名操作，需要先移除旧路径并创建删除记录（Tombstone）
            if changeType == .renamed, let oldPath = matchedRenameOldPath {
                // 重要：必须为旧路径创建原子性删除记录（Tombstone），
                // 否则同步引擎在扫描时因为 oldPath 已经从 lastKnown 中移除且硬盘上也已消失，
                // 会认为该路径从未存在过，从而导致无法向远端发送删除请求。
                if let myPeerID = p2pNode.peerID?.b58String, !myPeerID.isEmpty {
                    deleteFileAtomically(
                        path: oldPath, syncID: folder.syncID, peerID: myPeerID)
                }

                lastKnownLocalPaths[folder.syncID]?.remove(oldPath)
                lastKnownMetadata[folder.syncID]?.removeValue(forKey: oldPath)
                AppLogger.syncPrint("[recordLocalChange] 🔄 已处理重命名操作的旧路径删除记录并移除: \(oldPath)")
            }

            // 新建或重命名：添加到已知路径列表
            if lastKnownLocalPaths[folder.syncID] == nil {
                lastKnownLocalPaths[folder.syncID] = Set<String>()
            }
            lastKnownLocalPaths[folder.syncID]?.insert(relativePath)

            // 计算并保存元数据
            if exists {
                do {
                    let hash = try await getHash()
                    let attrs = try? fileManager.attributesOfItem(atPath: canonicalAbsolutePath)
                    let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
                    let creationDate = attrs?[.creationDate] as? Date

                    if lastKnownMetadata[folder.syncID] == nil {
                        lastKnownMetadata[folder.syncID] = [:]
                    }
                    lastKnownMetadata[folder.syncID]?[relativePath] = FileMetadata(
                        hash: hash,
                        mtime: mtime, size: size ?? 0,
                        creationDate: creationDate,
                        vectorClock: updatedVC
                    )
                    AppLogger.syncPrint("[recordLocalChange] 🔄 已更新已知路径和元数据: \(relativePath)")
                } catch {
                    AppLogger.syncPrint("[recordLocalChange] ⚠️ 无法计算哈希值以更新元数据: \(error)")
                }
            }
        } else if changeType == .modified {
            // 修改：更新元数据
            if exists {
                do {
                    let hash = try await getHash()
                    let attrs = try? fileManager.attributesOfItem(atPath: canonicalAbsolutePath)
                    let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
                    let creationDate = attrs?[.creationDate] as? Date

                    if lastKnownMetadata[folder.syncID] == nil {
                        lastKnownMetadata[folder.syncID] = [:]
                    }
                    lastKnownMetadata[folder.syncID]?[relativePath] = FileMetadata(
                        hash: hash,
                        mtime: mtime, size: size ?? 0,
                        creationDate: creationDate,
                        vectorClock: updatedVC
                    )
                    AppLogger.syncPrint("[recordLocalChange] 🔄 已更新元数据: \(relativePath)")
                } catch {
                    AppLogger.syncPrint("[recordLocalChange] ⚠️ 无法计算哈希值以更新元数据: \(error)")
                }
            }
        } else if changeType == .deleted {
            // 删除：从已知路径列表中移除
            lastKnownLocalPaths[folder.syncID]?.remove(relativePath)
            lastKnownMetadata[folder.syncID]?.removeValue(forKey: relativePath)
            AppLogger.syncPrint("[recordLocalChange] 🔄 已从已知路径和元数据中移除: \(relativePath)")
        }

        if saveToDisk {
            Task.detached {
                try? StorageManager.shared.addLocalChange(change)
                AppLogger.syncPrint(
                    "[recordLocalChange] 💾 已保存\(changeType == .created ? "新建" : changeType == .renamed ? "重命名" : changeType == .deleted ? "删除" : "修改")记录: \(relativePath)"
                )
            }
        }
        return (change, saveToDisk ? nil : updatedVC)
    }

    /// 批量记录本地变更（性能优化版）
    /// - 并行计算哈希（IO 密集型操作剥离到后台）
    /// - 批量写入变更日志（减少磁盘 IO）
    /// 批量记录本地变更（性能优化版）
    /// - 并行计算哈希（IO 密集型操作剥离到后台）
    /// - 批量写入变更日志（减少磁盘 IO）
    /// - Returns: Bool indicating if any changes were recorded
    @discardableResult
    func recordBatchLocalChanges(
        for folder: SyncFolder, paths: Set<String>, flags: [String: FSEventStreamEventFlags]
    ) async -> Bool {
        if paths.isEmpty { return false }

        AppLogger.syncPrint("[recordBatchLocalChanges] 🚀 开始批量处理 \(paths.count) 个文件变更")
        let start = Date()

        // 1. 预过滤：排除显而易见的忽略文件（避免无效的并发任务）
        // 这里只是简单的字符串检查，不进行文件系统调用
        var candidatePaths: [String] = []
        for absolutePath in paths {
            let relativePath = getRelativePath(
                absolutePath: absolutePath, base: folder.localPath.path)

            // 忽略 .DS_Store 及其他忽略规则
            if relativePath == "." || relativePath.hasSuffix("/.DS_Store")
                || isIgnored(relativePath, folder: folder)
                || ConflictFileFilter.isConflictFile(relativePath)
            {
                continue
            }
            candidatePaths.append(absolutePath)
        }

        if candidatePaths.isEmpty {
            AppLogger.syncPrint("[recordBatchLocalChanges] ⏭️ 所有文件均被忽略或无效")
            return false
        }

        // 2. 并行计算哈希（仅对存在的文件）
        // 使用 TaskGroup 并发执行哈希计算
        let fileHashes = await withTaskGroup(of: (String, String?).self) { group in
            for absolutePath in candidatePaths {
                group.addTask {
                    let fileURL = URL(fileURLWithPath: absolutePath)

                    // 检查文件是否存在且非目录
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDir) {
                        if isDir.boolValue {
                            return (absolutePath, "DIRECTORY")
                        }
                        // 计算哈希（computeFileHash 是 nonisolated，会在后台线程运行）
                        if let hash = try? await self.computeFileHash(fileURL: fileURL) {
                            return (absolutePath, hash)
                        }
                    }
                    return (absolutePath, nil)
                }
            }

            var results: [String: String] = [:]
            for await (path, hash) in group {
                if let h = hash {
                    results[path] = h
                }
            }
            return results
        }

        // 3. 串行执行业务逻辑（MainActor）并收集变更
        // 这里必须串行，因为 recordLocalChange 会修改 context 状态 (lastKnownMetadata 等)
        var changesToSave: [LocalChange] = []
        var vcsToSave: [String: VectorClock] = [:]

        for absolutePath in paths {  // 遍历原始 paths，确保不遗漏删除事件（candidatePaths 可能只包含存在的文件）
            let flag = flags[absolutePath] ?? FSEventStreamEventFlags(kFSEventStreamEventFlagNone)

            // 如果我们在预计算中有名单，使用预计算的哈希
            // 如果没有（例如文件被删除），precomputedHash 为 nil，recordLocalChange 会正确处理
            let precomputedHash = fileHashes[absolutePath]

            // 调用核心逻辑，但仅收集结果，不写入磁盘
            let (change, vc) = await recordLocalChange(
                for: folder,
                absolutePath: absolutePath,
                flags: flag,
                precomputedHash: precomputedHash,
                saveToDisk: false
            )

            if let c = change {
                changesToSave.append(c)
            }
            if let v = vc {
                vcsToSave[
                    getRelativePath(absolutePath: absolutePath, base: folder.localPath.path)] = v
            }
        }

        let batchVCs = vcsToSave  // Capture for task block
        let folderID = folder.id
        let syncID = folder.syncID

        // 4. 批量写入磁盘
        if !changesToSave.isEmpty || !batchVCs.isEmpty {
            let count = changesToSave.count
            let vcCount = batchVCs.count
            Task.detached {
                if !changesToSave.isEmpty {
                    do {
                        try StorageManager.shared.addLocalChanges(changesToSave)
                        AppLogger.syncPrint("[recordBatchLocalChanges] 💾 批量保存了 \(count) 条变更记录")
                    } catch {
                        AppLogger.syncPrint("[recordBatchLocalChanges] ❌ 批量保存变更记录失败: \(error)")
                    }
                }

                if !batchVCs.isEmpty {
                    await VectorClockManager.saveVectorClocks(
                        folderID: folderID, syncID: syncID, updates: batchVCs)
                    AppLogger.syncPrint(
                        "[recordBatchLocalChanges] 💾 批量保存了 \(vcCount) 个 VectorClock")
                }
            }
        }

        // 5. 触发增量更新（通知 Statistics）
        // 这里的 changesToSave 包含的是 LocalChange 对象，path 是相对路径
        let changedRelativePaths = Set(changesToSave.map { $0.path })
        if !changedRelativePaths.isEmpty {
            self.refreshFileCount(for: folder, changedPaths: changedRelativePaths)
        }

        let duration = Date().timeIntervalSince(start)
        AppLogger.syncPrint(
            "[recordBatchLocalChanges] ✅ 完成批量处理，耗时: \(String(format: "%.3f", duration))s")

        return !changesToSave.isEmpty
    }

    // 辅助函数：获取相对路径
    private func getRelativePath(absolutePath: String, base: String) -> String {
        // 标准化路径以确保匹配
        let standardAbs = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        let standardBase = URL(fileURLWithPath: base).standardizedFileURL.path

        if standardAbs.hasPrefix(standardBase) {
            var relative = String(standardAbs.dropFirst(standardBase.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            if relative.isEmpty { return "." }
            return relative
        }
        return absolutePath  // Fallback
    }

    /// 在重命名检测窗口到期后兜底处理删除（避免没有后续事件导致删除不被记录）
    private func schedulePendingRenameTimeout(
        folder: SyncFolder,
        relativePath: String,
        pendingKey: String,
        scheduledAt: Date
    ) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.renameDetectionWindow * 1_000_000_000))
            guard let pending = self.pendingRenames[pendingKey], pending.timestamp == scheduledAt
            else {
                return
            }

            let fileURL = folder.localPath.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return
            }

            AppLogger.syncPrint(
                "[recordLocalChange] ⏰ 重命名等待超时，确认为删除: \(relativePath) (syncID: \(folder.syncID))")

            if let myPeerID = self.p2pNode.peerID?.b58String, !myPeerID.isEmpty {
                self.deleteFileAtomically(
                    path: relativePath, syncID: folder.syncID, peerID: myPeerID)
            } else {
                var dp = self.deletedPaths(for: folder.syncID)
                dp.insert(relativePath)
                self.updateDeletedPaths(dp, for: folder.syncID)
            }

            let change = LocalChange(
                folderID: folder.id,
                path: relativePath,
                changeType: .deleted,
                size: nil,
                timestamp: Date(),
                sequence: nil
            )

            Task.detached {
                try? StorageManager.shared.addLocalChange(change)
                AppLogger.syncPrint("[recordLocalChange] 💾 已保存删除记录（重命名超时兜底）: \(relativePath)")
            }

            self.refreshFileCount(for: folder, changedPaths: [relativePath])
            self.pendingRenames.removeValue(forKey: pendingKey)
        }
    }
}
