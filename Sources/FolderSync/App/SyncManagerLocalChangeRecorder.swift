import CoreServices
import Foundation

/// 本地变更记录扩展
/// 负责记录和处理本地文件系统的变更事件
extension SyncManager {
    func recordLocalChange(
        for folder: SyncFolder, absolutePath: String, flags: FSEventStreamEventFlags
    ) {
        // macOS 上 `/var` 是 `/private/var` 的符号链接，FSEvents 可能返回不同前缀。
        // 这里统一做路径规范化，避免出现类似 "private/xxx" 的错误相对路径，进而导致同步找不到文件。
        let basePath = folder.localPath.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalAbsolutePath = URL(fileURLWithPath: absolutePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard canonicalAbsolutePath.hasPrefix(basePath) else { return }

        var relativePath = String(canonicalAbsolutePath.dropFirst(basePath.count))
        if relativePath.hasPrefix("/") { relativePath.removeFirst() }
        if relativePath.isEmpty { relativePath = "." }

        // 有任何文件变更，立即使该文件夹的状态缓存失效
        folderStatistics.invalidateCache(for: folder.syncID)

        // 如果该路径刚被“同步落地写入”，忽略本地事件记录，避免把“同步落地写入”误当成本地编辑
        let cooldownKey = "\(folder.syncID):\(relativePath)"
        if let lastWriteTime = syncWriteCooldown[cooldownKey],
            Date().timeIntervalSince(lastWriteTime) < syncCooldownDuration
        {
            return
        }

        // 忽略文件夹本身（根路径）
        if relativePath == "." {
            AppLogger.syncPrint("[recordLocalChange] ⏭️ 忽略文件夹本身: \(relativePath)")
            return
        }

        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: canonicalAbsolutePath)

        // 检查是否为目录，如果是目录则忽略（只记录文件变更）
        // 但需要清除该路径的删除记录（如果存在），因为目录的创建意味着该路径不再被删除
        if exists {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: canonicalAbsolutePath, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                // 检查是否有删除记录，如果有则清除（目录创建意味着路径不再被删除）
                // 同时需要从 lastKnownMetadata 中移除该路径的元数据（如果存在），因为目录不应该有文件元数据
                let stateStore = getFileStateStore(for: folder.syncID)
                if stateStore.getState(for: relativePath)?.isDeleted == true {
                    AppLogger.syncPrint("[recordLocalChange] 🔄 检测到目录创建，清除删除记录: \(relativePath)")
                    // 移除删除状态（使用 removeState 清除整个状态，包括删除记录）
                    stateStore.removeState(path: relativePath)
                    // 同时从旧的删除记录格式中移除
                    lastKnownLocalPaths[folder.syncID]?.insert(relativePath)
                    // 更新 deletedPaths（兼容性）
                    var dp = deletedPaths(for: folder.syncID)
                    dp.remove(relativePath)
                    updateDeletedPaths(dp, for: folder.syncID)
                }

                // 从 lastKnownMetadata 和 lastKnownLocalPaths 中移除该路径的元数据（如果存在），因为目录不应该有文件元数据
                // 这样可以防止系统尝试将目录作为文件上传
                if lastKnownMetadata[folder.syncID]?[relativePath] != nil {
                    AppLogger.syncPrint("[recordLocalChange] 🔄 检测到目录创建，移除文件元数据: \(relativePath)")
                    lastKnownMetadata[folder.syncID]?.removeValue(forKey: relativePath)
                }
                // 同时从 lastKnownLocalPaths 中移除，防止系统尝试将目录作为文件处理
                if lastKnownLocalPaths[folder.syncID]?.contains(relativePath) == true {
                    AppLogger.syncPrint("[recordLocalChange] 🔄 检测到目录创建，移除已知路径: \(relativePath)")
                    lastKnownLocalPaths[folder.syncID]?.remove(relativePath)
                }
                AppLogger.syncPrint("[recordLocalChange] ⏭️ 忽略目录（只记录文件变更）: \(relativePath)")
                return
            }
        }

        // 忽略冲突文件（冲突文件不应该被同步，避免无限循环）
        if ConflictFileFilter.isConflictFile(relativePath) {
            AppLogger.syncPrint("[recordLocalChange] ⏭️ 忽略冲突文件: \(relativePath)")
            return
        }

        // 忽略排除规则或隐藏文件
        if isIgnored(relativePath, folder: folder) {
            AppLogger.syncPrint("[recordLocalChange] ⏭️ 忽略文件（排除规则）: \(relativePath)")
            return
        }

        // 清理过期的待处理重命名操作，并将过期的转换为删除操作
        // 重要：只处理当前文件夹的过期条目，避免影响其他文件夹的状态
        let now = Date()
        var expiredRenames: [String] = []  // 存储过期的重命名操作的路径

        // 只过滤当前文件夹的过期条目，保留其他文件夹的条目
        let currentFolderPrefix = "\(folder.syncID):"
        pendingRenames = pendingRenames.filter { key, value in
            // 如果不是当前文件夹的条目，保留它（不处理）
            guard key.hasPrefix(currentFolderPrefix) else {
                return true  // 保留其他文件夹的条目
            }

            let isExpired = now.timeIntervalSince(value.timestamp) > renameDetectionWindow
            if isExpired {
                // 提取路径（移除 syncID 前缀）
                let path = String(key.dropFirst(currentFolderPrefix.count))
                expiredRenames.append(path)
                return false  // 移除过期的条目
            }
            return true  // 保留未过期的条目
        }

        // 将过期的重命名操作转换为删除操作（只处理当前文件夹）
        for expiredPath in expiredRenames {
            // 检查文件是否真的不存在（可能已经被删除）
            let expiredFileURL = folder.localPath.appendingPathComponent(expiredPath)
            if !fileManager.fileExists(atPath: expiredFileURL.path) {
                // 文件不存在，这是真正的删除，不是重命名
                AppLogger.syncPrint(
                    "[recordLocalChange] ⏰ 重命名操作超时，转换为删除操作: \(expiredPath) (syncID: \(folder.syncID))"
                )
                let change = LocalChange(
                    folderID: folder.id,
                    path: expiredPath,
                    changeType: .deleted,
                    size: nil,
                    timestamp: Date(),
                    sequence: nil
                )
                // 立即从已知路径列表中移除（如果还在）
                lastKnownLocalPaths[folder.syncID]?.remove(expiredPath)
                lastKnownMetadata[folder.syncID]?.removeValue(forKey: expiredPath)
                AppLogger.syncPrint("[recordLocalChange] 🔄 已从已知路径和元数据中移除: \(expiredPath)")

                Task.detached {
                    try? StorageManager.shared.addLocalChange(change)
                    AppLogger.syncPrint("[recordLocalChange] 💾 已保存删除记录（从过期重命名转换）: \(expiredPath)")
                }
            }
        }

        // 去重检查：短时间内的重复事件通常可忽略，但“创建→写入完成”的场景可能在 1 秒内发生多次变更。
        // 若内容哈希已发生变化，则不应去重，否则会导致 VectorClock 未更新、进而被误判为冲突（VC 相等但 hash 不同）。
        let changeKey = "\(folder.syncID):\(relativePath)"
        if let lastProcessed = recentChanges[changeKey],
            now.timeIntervalSince(lastProcessed) < changeDeduplicationWindow
        {
            if exists, let knownMeta = lastKnownMetadata[folder.syncID]?[relativePath] {
                let currentHash =
                    (try? computeFileHash(fileURL: URL(fileURLWithPath: canonicalAbsolutePath)))
                    ?? knownMeta.hash
                if currentHash == knownMeta.hash {
                    AppLogger.syncPrint(
                        "[recordLocalChange] ⏭️ 跳过重复事件（去重）: \(relativePath) (距离上次处理 \(String(format: "%.2f", now.timeIntervalSince(lastProcessed))) 秒)"
                    )
                    return
                }
                // 哈希不同：允许继续处理该事件（避免漏记真实变更）
            } else {
                AppLogger.syncPrint(
                    "[recordLocalChange] ⏭️ 跳过重复事件（去重）: \(relativePath) (距离上次处理 \(String(format: "%.2f", now.timeIntervalSince(lastProcessed))) 秒)"
                )
                return
            }
        }
        // 记录本次处理时间
        recentChanges[changeKey] = now

        var size: Int64?
        if exists,
            let attrs = try? fileManager.attributesOfItem(atPath: absolutePath),
            let s = attrs[.size] as? Int64
        {
            size = s
        }

        // 检查文件是否在已知路径列表中，用于区分新建和修改
        let isKnownPath = lastKnownLocalPaths[folder.syncID]?.contains(relativePath) ?? false

        // 解析 FSEvents 标志
        let hasRemovedFlag =
            (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0)
        let hasCreatedFlag =
            (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0)
        let hasModifiedFlag =
            (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0)
        let hasRenamedFlag =
            (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0)

        AppLogger.syncPrint("[recordLocalChange] 📝 开始处理变更:")
        AppLogger.syncPrint("  - 文件路径: \(relativePath)")
        AppLogger.syncPrint("  - 绝对路径: \(absolutePath)")
        AppLogger.syncPrint("  - 文件存在: \(exists)")
        AppLogger.syncPrint("  - 文件大小: \(size ?? 0) bytes")
        AppLogger.syncPrint("  - 在已知路径: \(isKnownPath)")
        AppLogger.syncPrint(
            "  - FSEvents 标志: Removed=\(hasRemovedFlag), Created=\(hasCreatedFlag), Modified=\(hasModifiedFlag), Renamed=\(hasRenamedFlag)"
        )

        // 逻辑判断：基于文件状态和已知路径列表确定变更类型
        // 1. 优先检查删除：如果文件不存在，且设置了 Removed 或 Renamed 标志
        // 注意：如果设置了 Renamed 标志且文件在已知路径中，可能是重命名操作，需要延迟判断
        if !exists {
            AppLogger.syncPrint("[recordLocalChange] 🔍 文件不存在，检查删除逻辑...")

            // 如果文件在已知路径中且设置了 Renamed 标志，可能是重命名操作
            // 但是，如果同时设置了 Removed 标志，这是明确的删除操作，不应该等待重命名
            // 只有在只有 Renamed 标志且没有 Removed 标志时，才可能等待重命名
            if isKnownPath && hasRenamedFlag && !hasRemovedFlag {
                if let knownMeta = lastKnownMetadata[folder.syncID]?[relativePath] {
                    // 检查是否有过期的重命名操作（可能已经超时，应该转换为删除）
                    let pendingKey = "\(folder.syncID):\(relativePath)"
                    if let existingPending = pendingRenames[pendingKey] {
                        // 如果已经有待处理的重命名操作，检查是否超时
                        if now.timeIntervalSince(existingPending.timestamp) > renameDetectionWindow
                        {
                            // 超时了，这是真正的删除，不是重命名
                            AppLogger.syncPrint(
                                "[recordLocalChange] ⏰ 待处理的重命名操作已超时，转换为删除操作: \(relativePath)")
                            pendingRenames.removeValue(forKey: pendingKey)
                            // 继续执行删除逻辑（不返回）
                        } else {
                            // 还在时间窗口内，继续等待新文件出现
                            AppLogger.syncPrint(
                                "[recordLocalChange] 🔄 检测到可能的重命名操作，保存旧文件哈希值: \(relativePath) (哈希: \(knownMeta.hash.prefix(16))...)"
                            )
                            // 暂时不记录，等待新文件出现
                            return
                        }
                    } else {
                        // 没有待处理的重命名操作，保存哈希值等待新文件出现
                        pendingRenames[pendingKey] = (hash: knownMeta.hash, timestamp: now)
                        schedulePendingRenameTimeout(
                            folder: folder, relativePath: relativePath, pendingKey: pendingKey,
                            scheduledAt: now)
                        AppLogger.syncPrint(
                            "[recordLocalChange] 🔄 检测到可能的重命名操作，保存旧文件哈希值: \(relativePath) (哈希: \(knownMeta.hash.prefix(16))...)"
                        )
                        // 暂时不记录，等待新文件出现
                        return
                    }
                }
            }

            // 重要：如果文件不在已知路径中但设置了 Renamed 标志，可能是重命名操作的旧路径
            // 这种情况下，不应该立即记录为删除，而应该等待新文件出现
            // 如果新文件出现且哈希值匹配，则记录为重命名；否则记录为删除
            if !isKnownPath && hasRenamedFlag && !hasRemovedFlag {
                // 文件不在已知路径中，但设置了 Renamed 标志，可能是重命名操作的旧路径
                // 这种情况下，不应该立即记录为删除，而应该等待新文件出现
                // 但是，由于文件不在已知路径中，我们无法获取其哈希值
                // 所以，这种情况下，应该跳过，不记录任何操作
                // 如果新文件出现，会在新文件的处理逻辑中检测重命名
                AppLogger.syncPrint(
                    "[recordLocalChange] ⏭️ 跳过：文件不在已知路径中但设置了 Renamed 标志，等待新文件出现以检测重命名: \(relativePath)"
                )
                return
            }

            // 如果文件在已知路径列表中，或者设置了 Removed 标志，记录为删除
            // 注意：如果只设置了 Renamed 标志但文件不在已知路径中，不应该记录为删除（已在上面处理）
            if isKnownPath || hasRemovedFlag {
                AppLogger.syncPrint(
                    "[recordLocalChange] ✅ 记录为删除: isKnownPath=\(isKnownPath), hasRemovedFlag=\(hasRemovedFlag), hasRenamedFlag=\(hasRenamedFlag)"
                )

                // 写入删除记录与 VectorClock，确保删除可同步到远端
                if let myPeerID = p2pNode.peerID?.b58String, !myPeerID.isEmpty {
                    deleteFileAtomically(
                        path: relativePath, syncID: folder.syncID, peerID: myPeerID)
                } else {
                    var dp = deletedPaths(for: folder.syncID)
                    dp.insert(relativePath)
                    updateDeletedPaths(dp, for: folder.syncID)
                }

                let change = LocalChange(
                    folderID: folder.id,
                    path: relativePath,
                    changeType: .deleted,
                    size: nil,
                    timestamp: Date(),
                    sequence: nil
                )
                // 立即从已知路径列表中移除
                lastKnownLocalPaths[folder.syncID]?.remove(relativePath)
                lastKnownMetadata[folder.syncID]?.removeValue(forKey: relativePath)
                AppLogger.syncPrint("[recordLocalChange] 🔄 已从已知路径和元数据中移除: \(relativePath)")

                Task.detached {
                    try? StorageManager.shared.addLocalChange(change)
                    AppLogger.syncPrint("[recordLocalChange] 💾 已保存删除记录: \(relativePath)")
                }
            } else {
                AppLogger.syncPrint("[recordLocalChange] ⏭️ 跳过：文件不存在但不在已知列表中，且无 Removed/Renamed 标志")
            }
            // 如果文件不在已知列表中，且没有 Removed/Renamed 标志，可能是从未存在过的文件，不记录
            return
        }

        // 2. 文件存在的情况
        // 如果文件在已知路径列表中，需要验证是否真的变化了
        if isKnownPath {
            AppLogger.syncPrint("[recordLocalChange] 🔍 文件在已知路径中，检查是否真的变化...")

            // 检查文件内容是否真的变化了（通过比较哈希值）
            if let knownMeta = lastKnownMetadata[folder.syncID]?[relativePath] {
                AppLogger.syncPrint(
                    "[recordLocalChange] 📊 找到已知元数据，哈希值: \(knownMeta.hash.prefix(16))...")
                do {
                    let fileURL = URL(fileURLWithPath: absolutePath)
                    let currentHash = try computeFileHash(fileURL: fileURL)
                    AppLogger.syncPrint(
                        "[recordLocalChange] 📊 当前文件哈希值: \(currentHash.prefix(16))...")

                    if currentHash == knownMeta.hash {
                        // 文件内容没有变化，可能是文件系统触发的误报（如复制操作时原文件触发事件）
                        // 不记录任何变更
                        AppLogger.syncPrint("[recordLocalChange] ⏭️ 跳过：文件内容未变化（哈希值相同），可能是复制操作时的误报")
                        return
                    } else {
                        // 文件内容确实变化了，记录为修改
                        AppLogger.syncPrint("[recordLocalChange] ✅ 记录为修改：文件内容已变化（哈希值不同）")
                        let change = LocalChange(
                            folderID: folder.id,
                            path: relativePath,
                            changeType: .modified,
                            size: size,
                            timestamp: Date(),
                            sequence: nil
                        )
                        Task.detached {
                            try? StorageManager.shared.addLocalChange(change)
                            AppLogger.syncPrint("[recordLocalChange] 💾 已保存修改记录: \(relativePath)")
                        }
                        return
                    }
                } catch {
                    AppLogger.syncPrint("[recordLocalChange] ⚠️ 无法计算哈希值: \(error)")
                    // 无法计算哈希值，根据标志判断
                    // 如果明确设置了 Modified 标志，记录为修改
                    if hasModifiedFlag {
                        AppLogger.syncPrint("[recordLocalChange] ✅ 记录为修改：无法计算哈希但设置了 Modified 标志")
                        let change = LocalChange(
                            folderID: folder.id,
                            path: relativePath,
                            changeType: .modified,
                            size: size,
                            timestamp: Date(),
                            sequence: nil
                        )
                        Task.detached {
                            try? StorageManager.shared.addLocalChange(change)
                            AppLogger.syncPrint("[recordLocalChange] 💾 已保存修改记录: \(relativePath)")
                        }
                    } else {
                        AppLogger.syncPrint("[recordLocalChange] ⏭️ 跳过：无法计算哈希且无 Modified 标志")
                    }
                    return
                }
            } else {
                // 文件在已知路径列表中，但没有元数据，可能是新添加的
                // 这种情况不应该发生，但为了安全，不记录
                AppLogger.syncPrint("[recordLocalChange] ⚠️ 文件在已知路径中但没有元数据，跳过记录")
                return
            }
        }

        // 3. 文件不在已知路径列表中，是新文件
        // 但需要检查是否有明确的 Created 标志，避免误判
        // 如果明确设置了 Removed 标志，不应该记录为新建（即使文件存在，可能是中间状态）
        if hasRemovedFlag {
            // 有 Removed 标志，即使文件存在，也不应该记录为新建
            // 可能是删除操作的中间状态，不记录
            AppLogger.syncPrint("[recordLocalChange] ⏭️ 跳过：文件不在已知路径中但设置了 Removed 标志（可能是删除中间状态）")
            return
        }

        // 检查是否是重命名（通过 Renamed 标志或哈希值匹配）
        let changeType: LocalChange.ChangeType

        // 首先检查是否有待处理的重命名操作（通过哈希值匹配）
        var matchedRename: String? = nil
        var isOldPathOfRename: Bool = false  // 标记是否是重命名操作的旧路径

        // 如果文件不在已知路径中，需要检查是否是重命名操作的旧路径
        // 即使没有 Renamed 标志，也要检查（因为从远程同步回来的文件可能没有该标志）
        if !isKnownPath {
            // 计算当前文件的哈希值
            do {
                let fileURL = URL(fileURLWithPath: absolutePath)
                let currentHash = try computeFileHash(fileURL: fileURL)

                // 检查是否有待处理的重命名操作（旧文件哈希值匹配）
                // 重要：如果新文件设置了 Renamed 标志，应该优先检查 pendingRenames
                if hasRenamedFlag {
                    for (pendingKey, pendingInfo) in pendingRenames {
                        let keyParts = pendingKey.split(separator: ":", maxSplits: 1)
                        if keyParts.count == 2, keyParts[0] == folder.syncID {
                            let oldPath = String(keyParts[1])
                            // 检查时间窗口和哈希值
                            if now.timeIntervalSince(pendingInfo.timestamp)
                                <= renameDetectionWindow,
                                pendingInfo.hash == currentHash
                            {
                                // 找到匹配的重命名操作
                                matchedRename = oldPath
                                AppLogger.syncPrint(
                                    "[recordLocalChange] 🔄 检测到重命名操作: \(oldPath) -> \(relativePath) (哈希值匹配)"
                                )
                                // 从待处理列表中移除
                                pendingRenames.removeValue(forKey: pendingKey)
                                break
                            }
                        }
                    }

                    // 如果设置了 Renamed 标志但没有找到匹配的 pendingRenames，尝试用已知元数据哈希匹配
                    if matchedRename == nil, let knownMetadata = lastKnownMetadata[folder.syncID] {
                        if let (oldPath, _) = knownMetadata.first(where: {
                            $0.value.hash == currentHash
                        }) {
                            matchedRename = oldPath
                            AppLogger.syncPrint(
                                "[recordLocalChange] 🔄 通过已知元数据哈希匹配检测到重命名: \(oldPath) -> \(relativePath)"
                            )
                        }
                    }

                    if matchedRename == nil {
                        AppLogger.syncPrint(
                            "[recordLocalChange] ⚠️ 新文件设置了 Renamed 标志但没有找到匹配的 pendingRenames，可能是旧文件不在已知路径中"
                        )
                    }
                }

                // 重要：如果文件不在已知路径中，且哈希值与某个 pendingRenames 中的旧路径匹配，
                // 需要区分两种情况：
                // 1. 如果文件设置了 Renamed 标志，说明这是重命名操作的新路径，应该记录为重命名
                // 2. 如果文件没有设置 Renamed 标志，说明这是重命名操作的旧路径（可能从远程同步回来），应该跳过
                if matchedRename == nil {
                    for (pendingKey, pendingInfo) in pendingRenames {
                        let keyParts = pendingKey.split(separator: ":", maxSplits: 1)
                        if keyParts.count == 2, keyParts[0] == folder.syncID {
                            let oldPath = String(keyParts[1])
                            // 检查哈希值（即使时间窗口已过，也检查哈希值，因为可能是从远程同步回来的）
                            if pendingInfo.hash == currentHash {
                                if hasRenamedFlag {
                                    // 文件设置了 Renamed 标志，说明这是重命名操作的新路径
                                    // 应该记录为重命名，而不是跳过
                                    matchedRename = oldPath
                                    AppLogger.syncPrint(
                                        "[recordLocalChange] 🔄 检测到重命名操作（通过 pendingRenames 和 Renamed 标志）: \(oldPath) -> \(relativePath) (哈希值匹配)"
                                    )
                                    // 从待处理列表中移除
                                    pendingRenames.removeValue(forKey: pendingKey)
                                    break
                                } else {
                                    // 没有 Renamed 标志，说明这是重命名操作的旧路径，不应该被记录为新建
                                    isOldPathOfRename = true
                                    AppLogger.syncPrint(
                                        "[recordLocalChange] ⏭️ 跳过：这是重命名操作的旧路径文件（哈希值与 pendingRenames 匹配，但无 Renamed 标志），不应该被记录为新建: \(relativePath) (旧路径: \(oldPath))"
                                    )
                                    break
                                }
                            }
                        }
                    }
                }

                // 重要：如果文件不在已知路径中，且哈希值与某个已知文件（可能是重命名的新路径）的哈希值匹配，
                // 说明这是重命名操作的旧路径文件（可能从远程同步回来），应该跳过，不记录为新建
                // 注意：这个检查应该在 pendingRenames 检查之后，因为如果 pendingRenames 中有匹配，说明重命名操作正在进行中
                // 但是，如果文件设置了 Renamed 标志，说明这是重命名操作的新路径，不应该跳过
                if !isOldPathOfRename && !hasRenamedFlag {
                    // 检查所有已知文件的哈希值（只有在没有 Renamed 标志时才检查，避免误判重命名操作的新路径）
                    if let knownMetadata = lastKnownMetadata[folder.syncID] {
                        for (knownPath, knownMeta) in knownMetadata {
                            if knownMeta.hash == currentHash {
                                // 哈希值匹配，说明这是重命名操作的旧路径（新路径已经在已知路径中）
                                // 但需要确认这不是同一个文件（路径不同）
                                if knownPath != relativePath {
                                    isOldPathOfRename = true
                                    AppLogger.syncPrint(
                                        "[recordLocalChange] ⏭️ 跳过：这是重命名操作的旧路径文件（哈希值与已知文件匹配），不应该被记录为新建: \(relativePath) (新路径: \(knownPath))"
                                    )
                                    break
                                }
                            }
                        }
                    }
                }
            } catch {
                AppLogger.syncPrint("[recordLocalChange] ⚠️ 无法计算哈希值以检测重命名: \(error)")
            }
        }

        // 如果是重命名操作的旧路径，跳过处理
        if isOldPathOfRename {
            return
        }

        if let oldPath = matchedRename {
            // 这是重命名操作（通过哈希值匹配确认）
            changeType = .renamed
            AppLogger.syncPrint(
                "[recordLocalChange] ✅ 记录为重命名：通过哈希值匹配检测到 \(oldPath) -> \(relativePath)")
        } else if hasCreatedFlag {
            // 明确设置了 Created 标志，记录为新建
            changeType = .created
            AppLogger.syncPrint("[recordLocalChange] ✅ 记录为新建：设置了 Created 标志")
        } else {
            // 没有明确的标志，但文件不在已知列表中，应该是新建（如复制文件）
            changeType = .created
            AppLogger.syncPrint("[recordLocalChange] ✅ 记录为新建：文件不在已知列表中且无明确标志（可能是复制文件）")
        }

        // 本地内容发生变化时，必须立即递增并持久化 VectorClock。
        // 否则在“内容已变但 VC 仍旧值”的窗口期，会出现 VC 相等但哈希不同，从而被误判为冲突。
        var updatedVC: VectorClock?
        if let myPeerID = p2pNode.peerID?.b58String, !myPeerID.isEmpty {
            if changeType == .renamed, let oldPath = matchedRename {
                _ = VectorClockManager.migrateVectorClock(
                    folderID: folder.id,
                    syncID: folder.syncID,
                    oldPath: oldPath,
                    newPath: relativePath
                )
            }
            let vc = VectorClockManager.updateForLocalChange(
                folderID: folder.id,
                syncID: folder.syncID,
                path: relativePath,
                peerID: myPeerID
            )
            VectorClockManager.saveVectorClock(
                folderID: folder.id, syncID: folder.syncID, path: relativePath, vc: vc)
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
            if changeType == .renamed, let oldPath = matchedRename {
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
                    let fileURL = URL(fileURLWithPath: canonicalAbsolutePath)
                    let hash = try computeFileHash(fileURL: fileURL)
                    let attrs = try? fileManager.attributesOfItem(atPath: canonicalAbsolutePath)
                    let mtime = (attrs?[.modificationDate] as? Date) ?? Date()

                    if lastKnownMetadata[folder.syncID] == nil {
                        lastKnownMetadata[folder.syncID] = [:]
                    }
                    lastKnownMetadata[folder.syncID]?[relativePath] = FileMetadata(
                        hash: hash,
                        mtime: mtime,
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
                    let fileURL = URL(fileURLWithPath: canonicalAbsolutePath)
                    let hash = try computeFileHash(fileURL: fileURL)
                    let attrs = try? fileManager.attributesOfItem(atPath: canonicalAbsolutePath)
                    let mtime = (attrs?[.modificationDate] as? Date) ?? Date()

                    if lastKnownMetadata[folder.syncID] == nil {
                        lastKnownMetadata[folder.syncID] = [:]
                    }
                    lastKnownMetadata[folder.syncID]?[relativePath] = FileMetadata(
                        hash: hash,
                        mtime: mtime,
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

        Task.detached {
            try? StorageManager.shared.addLocalChange(change)
            AppLogger.syncPrint(
                "[recordLocalChange] 💾 已保存\(changeType == .created ? "新建" : changeType == .renamed ? "重命名" : changeType == .deleted ? "删除" : "修改")记录: \(relativePath)"
            )
        }
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

            self.pendingRenames.removeValue(forKey: pendingKey)
        }
    }
}
