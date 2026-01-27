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
                  let remoteVC = remoteMeta.vectorClock else {
                // 如果远程存在但没有元数据或 Vector Clock，下载
                return remoteState != nil ? .download : .skip
            }
            
            // 比较删除记录的 Vector Clock 和文件元数据的 Vector Clock
            let comparison = localDel.vectorClock.compare(to: remoteVC)
            
            switch comparison {
            case .successor, .equal:
                // 删除记录的 VC 更新或相等，保持删除
                return .skip
            case .antecedent:
                // 删除记录的 VC 更旧，下载远程文件（删除被覆盖）
                return .download
            case .concurrent:
                // 并发冲突，保守处理：保持删除，但记录冲突
                return .conflict
            }
        }
        
        // 4. 如果远程已删除，本地存在
        if remoteDeleted {
            guard let remoteDel = remoteState?.deletionRecord,
                  let localMeta = localState?.metadata,
                  let localVC = localMeta.vectorClock else {
                // 如果本地存在但没有元数据或 Vector Clock，删除本地
                return localState != nil ? .deleteLocal : .skip
            }
            
            // 比较删除记录的 Vector Clock 和文件元数据的 Vector Clock
            let comparison = remoteDel.vectorClock.compare(to: localVC)
            
            switch comparison {
            case .successor, .equal:
                // 删除记录的 VC 更新或相等，删除本地文件
                return .deleteLocal
            case .antecedent:
                // 删除记录的 VC 更旧，上传本地文件（删除被覆盖）
                return .upload
            case .concurrent:
                // 并发冲突，保守处理：删除本地，但记录冲突
                return .conflict
            }
        }
        
        // 5. 双方都存在，比较文件元数据
        if let localMeta = localState?.metadata,
           let remoteMeta = remoteState?.metadata {
            return compareFileMetadata(local: localMeta, remote: remoteMeta)
        }
        
        // 6. 只有一方存在
        if localState != nil && remoteState == nil {
            return .upload
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
              !localVC.versions.isEmpty || !remoteVC.versions.isEmpty else {
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
            // Vector Clock 相同但哈希不同，视为冲突
            print(
                "[SyncDecisionEngine] ⚠️ VectorClock 相等但哈希不同，视为冲突。" +
                " localHash=\(local.hash), remoteHash=\(remote.hash)"
            )
            return .conflict
            
        case .concurrent:
            // 并发冲突，需要保存多版本
            return .conflict
        }
    }
}
