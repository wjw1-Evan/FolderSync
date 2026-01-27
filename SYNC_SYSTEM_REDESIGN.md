# 无服务器多端文件同步系统 - 重新设计

## 一、当前设计的问题分析

### 1. 删除操作处理不清晰
- **问题**：删除记录（tombstones）和文件状态分离，导致状态不一致
- **表现**：删除文件后，Vector Clock 可能还存在，导致文件被重新同步
- **根本原因**：删除操作没有作为文件状态的一部分统一管理

### 2. Vector Clock 与文件状态不同步
- **问题**：Vector Clock 相等但哈希不同的情况频繁出现
- **表现**：大量冲突文件被创建，文件被重复同步
- **根本原因**：Vector Clock 更新时机不当，删除时没有正确更新 VC

### 3. 删除记录清理逻辑复杂
- **问题**：删除记录的清理时机难以确定，容易过早清理
- **表现**：删除记录被清理后，离线客户端上线时文件被重新同步
- **根本原因**：删除确认机制不完善，没有考虑多客户端场景

### 4. 同步决策逻辑分散
- **问题**：删除检查、冲突检测、同步决策分散在多个地方
- **表现**：逻辑不一致，容易遗漏边界情况
- **根本原因**：缺乏统一的状态管理和决策流程

## 二、新设计原则

### 1. 统一的状态表示
- **文件状态统一管理**：文件存在/不存在状态应该统一表示
- **删除即状态**：删除不是"操作"，而是"状态"（文件不存在）
- **Vector Clock 与状态一致**：Vector Clock 必须与文件状态保持一致

### 2. 原子性操作
- **删除操作原子性**：删除文件时，必须同时：
  1. 删除文件
  2. 更新 Vector Clock（标记为删除）
  3. 记录删除时间戳和删除者
- **同步操作原子性**：同步决策和执行必须原子化

### 3. 删除即传播
- **删除记录即文件元数据**：删除记录应该像文件元数据一样传播
- **删除记录持久化**：删除记录应该持久化存储，直到所有客户端确认
- **删除记录合并**：多个客户端的删除记录应该合并

### 4. 简化的同步逻辑
- **先检查删除，再处理文件**：同步时先检查删除记录，再处理文件
- **统一决策流程**：所有同步决策通过统一的流程处理
- **状态优先于操作**：状态检查优先于操作执行

## 三、新设计方案

### 1. 文件状态模型

```swift
/// 文件状态枚举
enum FileState {
    /// 文件存在
    case exists(FileMetadata)
    /// 文件已删除（tombstone）
    case deleted(DeletionRecord)
}

/// 文件元数据
struct FileMetadata: Codable {
    let hash: String
    let mtime: Date
    let vectorClock: VectorClock
    let size: Int64
}

/// 删除记录
struct DeletionRecord: Codable {
    let deletedAt: Date
    let deletedBy: String  // PeerID
    let vectorClock: VectorClock  // 删除时的 Vector Clock
}
```

### 2. 统一的状态存储

```swift
/// 文件状态存储
class FileStateStore {
    /// 文件状态映射：path -> FileState
    private var states: [String: FileState] = [:]
    
    /// 获取文件状态
    func getState(for path: String) -> FileState? {
        return states[path]
    }
    
    /// 设置文件存在
    func setExists(path: String, metadata: FileMetadata) {
        states[path] = .exists(metadata)
    }
    
    /// 设置文件删除
    func setDeleted(path: String, record: DeletionRecord) {
        states[path] = .deleted(record)
    }
    
    /// 检查文件是否已删除
    func isDeleted(path: String) -> Bool {
        if case .deleted = states[path] {
            return true
        }
        return false
    }
}
```

### 3. 删除操作流程

```swift
/// 删除文件（原子操作）
func deleteFile(path: String, peerID: String) {
    // 1. 获取当前 Vector Clock
    let currentVC = getVectorClock(path: path) ?? VectorClock()
    
    // 2. 递增 Vector Clock（标记删除操作）
    currentVC.increment(for: peerID)
    
    // 3. 创建删除记录
    let deletionRecord = DeletionRecord(
        deletedAt: Date(),
        deletedBy: peerID,
        vectorClock: currentVC
    )
    
    // 4. 原子性更新状态
    fileStateStore.setDeleted(path: path, record: deletionRecord)
    
    // 5. 删除文件（如果存在）
    if fileManager.fileExists(atPath: path) {
        try? fileManager.removeItem(atPath: path)
    }
    
    // 6. 保存 Vector Clock（标记为删除状态）
    saveVectorClock(path: path, vectorClock: currentVC)
    
    // 7. 触发同步
    triggerSync()
}
```

### 4. 同步决策流程

```swift
/// 同步决策（统一流程）
func decideSyncAction(
    localState: FileState?,
    remoteState: FileState?,
    path: String
) -> SyncAction {
    // 1. 先检查删除状态
    let localDeleted = isDeleted(state: localState)
    let remoteDeleted = isDeleted(state: remoteState)
    
    // 2. 如果双方都已删除，跳过
    if localDeleted && remoteDeleted {
        return .skip
    }
    
    // 3. 如果本地已删除，远程存在
    if localDeleted {
        // 比较删除记录的 Vector Clock
        if let localDel = getDeletionRecord(state: localState),
           let remoteMeta = getMetadata(state: remoteState) {
            // 如果删除记录的 VC 更新，保持删除
            if localDel.vectorClock.compare(to: remoteMeta.vectorClock) == .successor {
                return .skip  // 保持删除
            }
            // 否则，下载远程文件（删除被覆盖）
            return .download
        }
        return .skip
    }
    
    // 4. 如果远程已删除，本地存在
    if remoteDeleted {
        // 比较删除记录的 Vector Clock
        if let remoteDel = getDeletionRecord(state: remoteState),
           let localMeta = getMetadata(state: localState) {
            // 如果删除记录的 VC 更新，删除本地文件
            if remoteDel.vectorClock.compare(to: localMeta.vectorClock) == .successor {
                return .deleteLocal  // 删除本地文件
            }
            // 否则，上传本地文件（删除被覆盖）
            return .upload
        }
        return .deleteLocal
    }
    
    // 5. 双方都存在，比较 Vector Clock
    if let localMeta = getMetadata(state: localState),
       let remoteMeta = getMetadata(state: remoteState) {
        return compareFileMetadata(local: localMeta, remote: remoteMeta)
    }
    
    // 6. 其他情况
    return .uncertain
}
```

### 5. 同步执行流程

```swift
/// 执行同步
func performSync(peerID: String) {
    // 1. 获取本地状态
    let localStates = fileStateStore.getAllStates()
    
    // 2. 获取远程状态
    let remoteStates = await requestRemoteStates(peerID: peerID)
    
    // 3. 合并所有路径
    let allPaths = Set(localStates.keys).union(Set(remoteStates.keys))
    
    // 4. 对每个路径进行决策
    for path in allPaths {
        let localState = localStates[path]
        let remoteState = remoteStates[path]
        
        let action = decideSyncAction(
            localState: localState,
            remoteState: remoteState,
            path: path
        )
        
        // 5. 执行操作
        switch action {
        case .skip:
            break
        case .download:
            await downloadFile(path: path, from: peerID)
        case .upload:
            await uploadFile(path: path, to: peerID)
        case .deleteLocal:
            deleteFile(path: path, peerID: self.peerID)
        case .deleteRemote:
            await requestDelete(path: path, to: peerID)
        case .conflict:
            handleConflict(path: path, local: localState, remote: remoteState)
        case .uncertain:
            handleUncertain(path: path, local: localState, remote: remoteState)
        }
    }
}
```

### 6. 删除记录传播

```swift
/// 同步消息扩展
enum SyncResponse: Codable {
    case files(
        syncID: String,
        entries: [String: FileState]  // 统一的状态表示
    )
    // ... 其他消息类型
}

/// 获取远程状态
func requestRemoteStates(peerID: String) async -> [String: FileState] {
    let response = await sendRequest(.getFiles(syncID: syncID))
    if case .files(let entries) = response {
        return entries
    }
    return [:]
}
```

### 7. 删除记录清理

```swift
/// 清理删除记录（保守策略）
func cleanupDeletionRecords() {
    let now = Date()
    let expirationTime: TimeInterval = 30 * 24 * 60 * 60  // 30天
    
    for (path, state) in fileStateStore.getAllStates() {
        if case .deleted(let record) = state {
            // 如果删除记录超过30天，且所有在线客户端都已确认删除
            if now.timeIntervalSince(record.deletedAt) > expirationTime {
                // 检查是否所有在线客户端都已确认
                if allPeersConfirmedDeletion(path: path) {
                    // 清理删除记录
                    fileStateStore.removeState(path: path)
                    deleteVectorClock(path: path)
                }
            }
        }
    }
}
```

## 四、实现步骤

### 阶段1：重构状态模型
1. 创建 `FileState` 枚举和 `DeletionRecord` 结构
2. 创建 `FileStateStore` 类统一管理状态
3. 修改 `FileMetadata` 和 `SyncMessage` 以支持统一状态

### 阶段2：重构删除操作
1. 实现原子性删除操作
2. 删除时更新 Vector Clock
3. 创建删除记录并保存

### 阶段3：重构同步决策
1. 实现统一的 `decideSyncAction` 函数
2. 先检查删除状态，再处理文件
3. 统一所有同步决策逻辑

### 阶段4：重构同步执行
1. 实现新的 `performSync` 流程
2. 统一状态获取和传播
3. 实现删除记录传播

### 阶段5：测试和优化
1. 测试各种场景（添加、删除、修改、重命名）
2. 测试离线客户端场景
3. 优化性能和稳定性

## 五、优势

1. **状态一致性**：文件状态统一管理，避免不一致
2. **逻辑简化**：删除操作和文件操作统一处理
3. **可靠性提升**：原子性操作保证状态一致
4. **易于维护**：清晰的流程和统一的状态管理
5. **扩展性强**：易于添加新功能和优化

## 六、迁移策略

1. **兼容性处理**：保留旧的删除记录格式，逐步迁移
2. **数据迁移**：将旧的删除记录转换为新的状态格式
3. **渐进式重构**：分阶段重构，确保每个阶段都能正常工作
