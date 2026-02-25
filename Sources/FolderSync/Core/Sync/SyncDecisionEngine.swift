import Foundation

/// 同步决策引擎
/// 统一处理所有同步决策，包括文件操作和删除操作
class SyncDecisionEngine {

    /// 同步操作类型
    enum SyncAction {
        /// 跳过（无需操作）
        case skip
        /// 下载文件（覆盖本地）
        case download
        /// 上传文件（覆盖远程）
        case upload
        /// 删除本地文件
        case deleteLocal
        /// 删除远程文件
        case deleteRemote
        /// 冲突（需要保存多版本）
        case conflict
        /// 不确定（需要保守处理）
        case uncertain
    }

    /// 统一的同步决策函数
    /// - Parameters:
    ///   - localState: 本地文件状态
    ///   - remoteState: 远程文件状态
    ///   - path: 文件路径
    /// - Returns: 同步操作
    static func decideSyncAction(
        localState: FileState?,
        remoteState: FileState?,
        path: String
    ) -> SyncAction {
        // 1. 先检查删除状态
        let localDeleted = localState?.isDeleted ?? false
        let remoteDeleted = remoteState?.isDeleted ?? false

        // 2. 如果双方都已删除，跳过
        if localDeleted && remoteDeleted {
            return .skip
        }

        // 3. 如果本地已删除，远程存在
        if localDeleted {
            guard let localDel = localState?.deletionRecord,
                let remoteMeta = remoteState?.metadata,
                let remoteVC = remoteMeta.vectorClock
            else {
                // 如果远程存在但没有元数据或 Vector Clock，下载
                return remoteState != nil ? .download : .skip
            }

            // 比较删除记录的 Vector Clock 和文件元数据的 Vector Clock
            let comparison = localDel.vectorClock.compare(to: remoteVC)

            switch comparison {
            case .successor, .equal:
                // 删除记录的 VC 更新或相等，说明删除操作是在这个文件版本之后（或同时）发生的
                // 除非文件 mtime 明显更新（可能存在 VC 丢失或手动覆盖），否则应该删除
                let timeDiff = remoteMeta.mtime.timeIntervalSince(localDel.deletedAt)
                if timeDiff > 0.5 {
                    AppLogger.syncPrint(
                        "[SyncDecisionEngine] 🔄 删除记录 VC 领先但远程文件 mtime 更新，视为冲突: 路径=\(path)")
                    return .conflict
                }
                return .deleteRemote
            case .antecedent:
                // 删除记录的 VC 更旧，说明文件是在删除知识的基础上更新的（复活）
                // 只有当时间极度接近（可能是时钟漂移导致的伪因果）时才报冲突
                let timeDiff = abs(remoteMeta.mtime.timeIntervalSince(localDel.deletedAt))
                if timeDiff < 0.2 {
                    AppLogger.syncPrint(
                        "[SyncDecisionEngine] ⚠️ 删除和修改时间极度接近（\(String(format: "%.3f", timeDiff))秒），视为并发冲突: 路径=\(path)"
                    )
                    return .conflict
                }
                return .download
            case .concurrent:
                // 并发冲突：如果远程文件明显比删除记录新，视为远程复活/新建，应该下载
                let timeDiff = remoteMeta.mtime.timeIntervalSince(localDel.deletedAt)
                if timeDiff > 0.5 {
                    AppLogger.syncPrint(
                        "[SyncDecisionEngine] 🔄 删除记录并发且远程文件较新，自动选择下载（复活）: 路径=\(path), diff=\(timeDiff)s"
                    )
                    return .download
                }
                return .conflict
            }
        }

        // 4. 如果远程已删除，本地存在
        if remoteDeleted {
            guard let remoteDel = remoteState?.deletionRecord,
                let localMeta = localState?.metadata
            else {
                // 如果本地存在但没有元数据或远程没有删除记录，保守处理：删除本地
                return localState != nil ? .deleteLocal : .skip
            }

            // 如果有 Vector Clock，使用标准比较逻辑
            if let localVC = localMeta.vectorClock {
                let comparison = remoteDel.vectorClock.compare(to: localVC)

                switch comparison {
                case .successor:
                    // 远程删除记录领先，删除本地文件
                    // 同样检查 mtime 异常
                    let timeDiff = localMeta.mtime.timeIntervalSince(remoteDel.deletedAt)
                    if timeDiff > 0.5 {
                        AppLogger.syncPrint(
                            "[SyncDecisionEngine] 🔄 远端删除领先但本地文件 mtime 更新，视为冲突: 路径=\(path)")
                        return .conflict
                    }
                    return .deleteLocal
                case .antecedent:
                    // 远程删除记录落后，说明本地是复活/更新
                    let timeDiff = abs(localMeta.mtime.timeIntervalSince(remoteDel.deletedAt))
                    if timeDiff < 0.2 {
                        AppLogger.syncPrint("[SyncDecisionEngine] ⚠️ 删除和修改时间极度接近，视为冲突: 路径=\(path)")
                        return .conflict
                    }
                    AppLogger.syncPrint("[SyncDecisionEngine] 🔄 远端删除记录过时，本地文件获胜（复活）: 路径=\(path)")
                    return .upload
                case .equal:
                    // VC 相等：使用更小的 epsilon
                    let timeDiff = localMeta.mtime.timeIntervalSince(remoteDel.deletedAt)
                    if timeDiff > 0.2 {
                        AppLogger.syncPrint(
                            "[SyncDecisionEngine] 🔄 删除记录 VC 相等但本地文件更新（复活）: 路径=\(path), diff=\(timeDiff)s"
                        )
                        return .upload
                    }
                    return .deleteLocal
                case .concurrent:
                    let timeDiff = localMeta.mtime.timeIntervalSince(remoteDel.deletedAt)
                    if timeDiff > 0.5 {
                        AppLogger.syncPrint(
                            "[SyncDecisionEngine] 🔄 存在并发删除记录，但本地文件更新（复活）: 路径=\(path), diff=\(timeDiff)s"
                        )
                        return .upload
                    }
                    return .conflict
                }
            } else {
                // strict safety:
                // 如果本地文件没有 Vector Clock (可能是新复制/创建的文件尚未同步VC)
                // 无论 mtime 如何，都视为新文件（复活/新建）
                // 这样可以最大限度防止数据丢失（Zero Data Loss）
                AppLogger.syncPrint(
                    "[SyncDecisionEngine] 🔄 本地文件无 VC，执行严格安全策略（视为新建/复活）: 路径=\(path)"
                )
                return .upload
            }
        }

        // 5. 双方都存在，比较文件元数据
        if let localMeta = localState?.metadata,
            let remoteMeta = remoteState?.metadata
        {
            return compareFileMetadata(local: localMeta, remote: remoteMeta)
        }

        // 6. 只有一方存在
        if localState != nil && remoteState == nil {
            // 重要：如果本地有文件，但远程没有，需要检查远程是否有删除记录
            // 如果远程有删除记录（在 remoteStates 中但没有这个路径），说明文件已被删除
            // 这种情况下不应该上传，应该跳过或删除本地
            // 注意：这里 remoteState == nil 可能意味着：
            // 1. 文件不存在（新文件，应该上传）
            // 2. 文件已删除但删除记录没有传播（不应该上传）
            // 为了安全，如果本地文件存在，但远程没有状态，保守处理为不确定
            // 让调用者根据 deletedSet 等额外信息来决定
            return .uncertain
        }
        if localState == nil && remoteState != nil {
            return .download
        }

        // 7. 其他情况（双方都不存在）
        return .skip
    }

    /// 比较文件元数据并做出决策
    private static func compareFileMetadata(
        local: FileMetadata,
        remote: FileMetadata
    ) -> SyncAction {
        // 1. 如果哈希值相同，内容一致，跳过同步
        if local.hash == remote.hash {
            return .skip
        }

        // 2. 检查 Vector Clock 是否有效
        guard let localVC = local.vectorClock,
            let remoteVC = remote.vectorClock,
            !localVC.versions.isEmpty || !remoteVC.versions.isEmpty
        else {
            // Vector Clock 为空，无法确定因果关系，保守处理为不确定
            return .uncertain
        }

        // 3. 比较 Vector Clock
        let comparison = localVC.compare(to: remoteVC)

        switch comparison {
        case .antecedent:
            // 本地版本落后于远程，需要下载覆盖本地
            return .download

        case .successor:
            // 本地版本领先于远程，需要上传覆盖远程
            return .upload

        case .equal:
            // Vector Clock 相同但哈希不同：理论上应视为冲突（说明因果信息缺失或时钟未正确更新）。
            // 但在实际文件系统事件/网络同步中，可能出现“同一版本号、内容仍在写入/落地”的短暂窗口。
            // 为了让系统最终收敛，这里引入基于 mtime 的启发式决策：
            // - 若 mtime 差距明显，选择较新的版本覆盖较旧版本；
            // - 若 mtime 接近（可能是真并发），仍视为冲突。
            let timeDelta = local.mtime.timeIntervalSince(remote.mtime)  // >0: 本地更新
            let epsilon: TimeInterval = 0.5
            if abs(timeDelta) >= epsilon {
                return timeDelta > 0 ? .upload : .download
            }
            AppLogger.syncPrint(
                "[SyncDecisionEngine] ⚠️ VectorClock 相等但哈希不同且 mtime 接近，视为冲突。"
                    + " localHash=\(local.hash), remoteHash=\(remote.hash)"
            )
            return .conflict

        case .concurrent:
            // 并发冲突，需要保存多版本
            return .conflict
        }
    }
}
