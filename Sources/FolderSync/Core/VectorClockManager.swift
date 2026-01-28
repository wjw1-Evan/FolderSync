import Foundation

/// Vector Clock 管理器
/// 负责统一管理 Vector Clock 的更新、合并、比较和决策逻辑
class VectorClockManager {
    
    /// 同步决策结果
    enum SyncDecision {
        /// 跳过同步（本地版本更新或相同）
        case skip
        /// 覆盖本地（远程版本更新）
        case overwriteLocal
        /// 覆盖远程（本地版本更新）
        case overwriteRemote
        /// 并发冲突（需要保存多版本）
        case conflict
        /// 无法确定（缺少 Vector Clock，需要保守处理）
        case uncertain
    }
    
    /// 比较两个 Vector Clock 并做出同步决策
    /// - Parameters:
    ///   - localVC: 本地文件的 Vector Clock（可选）
    ///   - remoteVC: 远程文件的 Vector Clock（可选）
    ///   - localHash: 本地文件哈希值
    ///   - remoteHash: 远程文件哈希值
    ///   - direction: 同步方向（用于确定决策语义）
    /// - Returns: 同步决策结果
    static func decideSyncAction(
        localVC: VectorClock?,
        remoteVC: VectorClock?,
        localHash: String,
        remoteHash: String,
        direction: SyncDirection
    ) -> SyncDecision {
        // 1. 如果哈希值相同，内容一致，跳过同步
        if localHash == remoteHash {
            return .skip
        }
        
        // 2. 如果本地文件不存在（localHash 为空字符串表示文件不存在），需要下载
        // 注意：调用者应该确保 localHash 为空字符串仅表示文件不存在，而不是空文件
        // 空文件的哈希值应该是非空的（如空字符串的哈希值）
        if localHash.isEmpty {
            return .overwriteLocal
        }
        
        // 3. 如果远程文件不存在（remoteHash 为空字符串表示文件不存在），需要上传
        // 注意：调用者应该确保 remoteHash 为空字符串仅表示文件不存在，而不是空文件
        if remoteHash.isEmpty {
            return .overwriteRemote
        }
        
        // 4. 检查 Vector Clock 是否有效（非空）
        guard let local = localVC, let remote = remoteVC,
              !local.versions.isEmpty || !remote.versions.isEmpty else {
            // Vector Clock 为空，无法确定因果关系，保守处理为不确定
            return .uncertain
        }
        
        // 5. 比较 Vector Clock
        let comparison = local.compare(to: remote)
        
        switch comparison {
        case .antecedent:
            // 本地版本落后于远程，需要下载覆盖本地
            return .overwriteLocal
            
        case .successor:
            // 本地版本领先于远程，需要上传覆盖远程
            return .overwriteRemote
            
        case .equal:
            // Vector Clock 相同但哈希不同，说明在某处没有正确更新 VC
            // 这种情况应该极少发生，视为冲突并记录详细日志以便排查
            print(
                "[VectorClockManager] ⚠️ VectorClock 相等但哈希不同，视为冲突。" +
                " localHash=\(localHash), remoteHash=\(remoteHash), direction=\(direction)"
            )
            return .conflict
            
        case .concurrent:
            // 并发冲突，需要保存多版本
            return .conflict
        }
    }
    
    /// 为文件创建或更新 Vector Clock（用于本地文件变更）
    /// - Parameters:
    ///   - syncID: 同步 ID
    ///   - path: 文件路径
    ///   - peerID: 当前设备的 PeerID
    /// - Returns: 更新后的 Vector Clock
    static func updateForLocalChange(
        folderID: UUID,
        syncID: String,
        path: String,
        peerID: String
    ) -> VectorClock {
        var vc = StorageManager.shared.getVectorClock(folderID: folderID, syncID: syncID, path: path)
            ?? VectorClock()
        vc.increment(for: peerID)
        return vc
    }
    
    /// 合并 Vector Clock（用于接收远程文件时）
    /// 
    /// 注意：接收文件时只合并 Vector Clock，不递增本地 peerID。
    /// Vector Clock 的递增只在本地文件变更时发生（通过 updateForLocalChange）。
    /// 这是正确的行为，因为接收文件不是本地事件，而是学习远程事件。
    /// 
    /// - Parameters:
    ///   - localVC: 本地现有的 Vector Clock（可选）
    ///   - remoteVC: 远程文件的 Vector Clock（可选）
    /// - Returns: 合并后的 Vector Clock
    static func mergeVectorClocks(
        localVC: VectorClock?,
        remoteVC: VectorClock?
    ) -> VectorClock {
        var merged = VectorClock()
        
        // 如果本地存在 VC，先合并本地
        if let local = localVC {
            merged.merge(with: local)
        }
        
        // 如果远程存在 VC，再合并远程
        if let remote = remoteVC {
            merged.merge(with: remote)
        }
        
        return merged
    }
    
    /// 迁移 Vector Clock（用于文件重命名）
    /// - Parameters:
    ///   - syncID: 同步 ID
    ///   - oldPath: 旧路径
    ///   - newPath: 新路径
    /// - Returns: 是否成功迁移
    @discardableResult
    static func migrateVectorClock(
        folderID: UUID,
        syncID: String,
        oldPath: String,
        newPath: String
    ) -> Bool {
        guard
            let oldVC = StorageManager.shared.getVectorClock(
                folderID: folderID, syncID: syncID, path: oldPath)
        else {
            // 旧路径没有 Vector Clock，无需迁移
            return false
        }
        
        do {
            // 迁移到新路径
            try StorageManager.shared.setVectorClock(folderID: folderID, syncID: syncID, path: newPath, oldVC)
            // 删除旧路径的 Vector Clock
            try? StorageManager.shared.deleteVectorClock(folderID: folderID, syncID: syncID, path: oldPath)
            return true
        } catch {
            print("[VectorClockManager] ⚠️ 迁移 Vector Clock 失败: \(oldPath) -> \(newPath), 错误: \(error)")
            return false
        }
    }
    
    /// 删除 Vector Clock（用于文件删除）
    /// - Parameters:
    ///   - syncID: 同步 ID
    ///   - path: 文件路径
    static func deleteVectorClock(folderID: UUID, syncID: String, path: String) {
        try? StorageManager.shared.deleteVectorClock(folderID: folderID, syncID: syncID, path: path)
    }
    
    /// 保存 Vector Clock
    /// - Parameters:
    ///   - syncID: 同步 ID
    ///   - path: 文件路径
    ///   - vc: Vector Clock
    static func saveVectorClock(folderID: UUID, syncID: String, path: String, vc: VectorClock) {
        do {
            try StorageManager.shared.setVectorClock(folderID: folderID, syncID: syncID, path: path, vc)
        } catch {
            print("[VectorClockManager] ⚠️ 保存 Vector Clock 失败: \(path), 错误: \(error)")
        }
    }
    
    /// 获取 Vector Clock
    /// - Parameters:
    ///   - syncID: 同步 ID
    ///   - path: 文件路径
    /// - Returns: Vector Clock（如果存在）
    static func getVectorClock(folderID: UUID, syncID: String, path: String) -> VectorClock? {
        return StorageManager.shared.getVectorClock(folderID: folderID, syncID: syncID, path: path)
    }
}

/// 同步方向枚举（用于明确决策语义）
enum SyncDirection {
    case download  // 下载方向：决定是否下载远程文件覆盖本地
    case upload    // 上传方向：决定是否上传本地文件覆盖远程
}
