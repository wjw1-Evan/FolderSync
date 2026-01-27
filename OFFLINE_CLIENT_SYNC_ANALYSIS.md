# 离线客户端同步机制分析与改进

## 当前机制分析

### 已实现的离线支持

1. **删除记录传播** ✅
   - 删除记录（tombstones）通过文件列表同步传播
   - 离线客户端上线后会收到删除记录并删除本地文件

2. **Vector Clock 传播** ✅
   - Vector Clock 包含在文件元数据中
   - 离线客户端上线后能收到所有 Vector Clock 更新
   - Vector Clock 合并机制确保因果关系正确

3. **文件列表同步** ✅
   - 通过 `getFiles` 请求获取完整的文件列表
   - 离线客户端上线后能收到所有文件变更

### 潜在问题

1. **lastKnown 更新时机**
   - `lastKnown` 只在同步成功后才更新
   - 如果同步失败或中断，`lastKnown` 不会更新
   - 可能导致离线客户端上线后误判文件状态

2. **删除记录清理时机**
   - 删除记录在远程文件列表中确认不存在后才清理
   - 但如果某个客户端一直离线，删除记录会一直保留
   - 需要确保删除记录在所有客户端都确认后才清理

3. **同步完整性检查**
   - 当前没有机制确保离线客户端上线后完整同步所有变化
   - 如果同步过程中断，可能只同步了部分文件

4. **多客户端删除确认**
   - 当前删除确认只检查单个远程客户端
   - 在多客户端场景下，需要所有客户端都确认删除后才能清理

## 改进方案

### 1. 改进 lastKnown 更新机制

**问题**：`lastKnown` 只在同步成功后才更新，如果同步失败，可能导致状态不一致。

**改进**：
- 在同步开始时保存当前状态快照
- 只有在同步完全成功后才更新 `lastKnown`
- 如果同步失败，回滚到之前的状态

### 2. 改进删除记录清理机制

**问题**：删除记录在单个客户端确认后就清理，但其他客户端可能还没收到删除记录。

**改进**：
- 删除记录应该保留更长时间（如30天）
- 或者实现多客户端确认机制
- 只有在所有在线客户端都确认删除后才清理

### 3. 添加同步完整性检查

**问题**：没有机制确保同步的完整性。

**改进**：
- 在同步开始时记录预期同步的文件数量
- 在同步结束时验证实际同步的文件数量
- 如果数量不匹配，标记为不完整并重试

### 4. 改进离线检测和重连机制

**问题**：离线客户端上线后可能不会立即同步。

**改进**：
- 检测到客户端上线后，立即触发同步
- 实现同步队列，确保所有待同步的操作都能执行
- 添加重试机制，确保同步失败后能重试

## 具体实现建议

### 1. 同步状态管理

```swift
struct SyncState {
    let syncID: String
    let peerID: String
    let startedAt: Date
    var expectedFiles: Set<String>
    var syncedFiles: Set<String>
    var failedFiles: Set<String>
    var isComplete: Bool
}
```

### 2. 删除记录生命周期管理

```swift
struct DeletedRecord {
    let path: String
    let deletedAt: Date
    let deletedBy: String  // PeerID
    var confirmedBy: Set<String>  // 确认删除的客户端列表
    var isExpired: Bool {
        Date().timeIntervalSince(deletedAt) > 30 * 24 * 60 * 60  // 30天
    }
}
```

### 3. 同步完整性验证

```swift
func verifySyncCompleteness(
    expected: Set<String>,
    actual: Set<String>
) -> SyncCompleteness {
    let missing = expected.subtracting(actual)
    let extra = actual.subtracting(expected)
    
    if missing.isEmpty && extra.isEmpty {
        return .complete
    } else {
        return .incomplete(missing: missing, extra: extra)
    }
}
```

## 优先级

### 高优先级
1. ✅ 删除记录传播（已实现）
2. ⚠️ 同步完整性检查
3. ⚠️ 离线客户端上线后立即同步

### 中优先级
4. ⚠️ lastKnown 更新机制改进
5. ⚠️ 删除记录生命周期管理

### 低优先级
6. ⚠️ 多客户端删除确认机制
7. ⚠️ 同步状态持久化
