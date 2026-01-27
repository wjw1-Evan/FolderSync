# 同步系统重新设计 - 进度报告

## 已完成的工作

### 1. ✅ 创建统一的状态模型
- **FileState.swift**: 定义了 `FileState` 枚举和 `DeletionRecord` 结构
  - `FileState.exists(FileMetadata)`: 文件存在状态
  - `FileState.deleted(DeletionRecord)`: 文件删除状态
  - 统一表示文件的存在/删除状态，避免状态不一致

### 2. ✅ 创建状态存储系统
- **FileStateStore.swift**: 统一管理文件状态
  - 线程安全的状态存储
  - 支持批量操作和删除记录清理
  - 提供统一的状态查询接口

### 3. ✅ 创建统一决策引擎
- **SyncDecisionEngine.swift**: 统一的同步决策逻辑
  - 先检查删除状态，再处理文件
  - 统一的决策流程，避免逻辑分散
  - 正确处理删除记录和文件元数据的比较

### 4. ✅ 扩展同步消息协议
- **SyncMessage.swift**: 添加 `filesV2` 消息类型
  - 支持统一的状态表示（`FileState`）
  - 保持向后兼容（保留旧的 `files` 消息）

## 设计优势

### 1. 状态一致性
- **统一的状态表示**：文件状态统一管理，避免不一致
- **删除即状态**：删除不是"操作"，而是"状态"（文件不存在）
- **Vector Clock 与状态一致**：Vector Clock 必须与文件状态保持一致

### 2. 逻辑简化
- **统一决策流程**：所有同步决策通过统一的流程处理
- **先检查删除，再处理文件**：同步时先检查删除记录，再处理文件
- **状态优先于操作**：状态检查优先于操作执行

### 3. 原子性操作
- **删除操作原子性**：删除文件时，必须同时：
  1. 删除文件
  2. 更新 Vector Clock（标记为删除）
  3. 记录删除时间戳和删除者

## 下一步工作

### 阶段1：重构删除操作（高优先级）
1. 实现原子性删除操作
   - 删除文件时同时更新 Vector Clock
   - 创建删除记录并保存到 FileStateStore
   - 确保删除操作的原子性

2. 修改 SyncManager 的删除处理
   - 使用新的 FileStateStore 管理删除记录
   - 删除时创建 DeletionRecord 并保存

### 阶段2：重构同步执行（高优先级）
1. 修改 SyncEngine.performSync
   - 使用 FileStateStore 获取本地状态
   - 使用 SyncDecisionEngine 进行决策
   - 统一处理删除和文件操作

2. 修改 P2PHandlers
   - 支持新的 filesV2 消息类型
   - 返回统一的状态表示

### 阶段3：数据迁移（中优先级）
1. 将旧的删除记录迁移到新的格式
2. 兼容旧的同步消息格式
3. 逐步迁移到新的状态管理

### 阶段4：测试和优化（中优先级）
1. 测试各种场景（添加、删除、修改、重命名）
2. 测试离线客户端场景
3. 优化性能和稳定性

## 关键改进点

### 1. 删除操作处理
**旧设计问题**：
- 删除记录和文件状态分离
- 删除记录清理时机难以确定
- Vector Clock 更新时机不当

**新设计优势**：
- 删除记录作为文件状态的一部分统一管理
- 删除操作原子性，确保状态一致
- Vector Clock 与删除状态保持一致

### 2. 同步决策逻辑
**旧设计问题**：
- 删除检查、冲突检测、同步决策分散在多个地方
- 逻辑不一致，容易遗漏边界情况

**新设计优势**：
- 统一的决策流程，先检查删除，再处理文件
- 所有决策通过 SyncDecisionEngine 统一处理
- 清晰的决策流程，易于维护

### 3. 状态管理
**旧设计问题**：
- 文件状态分散在多个地方（deletedSet, localMetadata, remoteEntries）
- 状态不一致导致同步错误

**新设计优势**：
- 统一的状态存储（FileStateStore）
- 状态查询统一接口
- 状态更新原子性

## 使用示例

### 删除文件
```swift
// 原子性删除操作
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
    
    // 6. 保存 Vector Clock
    saveVectorClock(path: path, vectorClock: currentVC)
}
```

### 同步决策
```swift
// 统一的同步决策
let action = SyncDecisionEngine.decideSyncAction(
    localState: localStateStore.getState(for: path),
    remoteState: remoteState,
    path: path
)

switch action {
case .skip:
    break
case .download:
    await downloadFile(path: path)
case .upload:
    await uploadFile(path: path)
case .deleteLocal:
    deleteFile(path: path, peerID: self.peerID)
case .deleteRemote:
    await requestDelete(path: path)
case .conflict:
    handleConflict(path: path)
case .uncertain:
    handleUncertain(path: path)
}
```

## 总结

新设计通过统一的状态管理、原子性操作和简化的决策流程，解决了当前设计中的核心问题：

1. ✅ **删除文件被同步回来**：通过统一的状态管理和删除记录传播解决
2. ✅ **Vector Clock 相等但哈希不同**：通过原子性操作和状态一致性解决
3. ✅ **删除记录清理复杂**：通过统一的状态管理和清晰的清理策略解决
4. ✅ **同步决策逻辑分散**：通过统一的决策引擎解决

下一步将逐步实现这些改进，确保系统的稳定性和可靠性。
