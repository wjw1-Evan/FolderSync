# Vector Clock 重构总结

## 已完成的重构

### 1. 创建 VectorClockManager 类 ✅
- 位置：`Sources/FolderSync/Core/VectorClockManager.swift`
- 功能：
  - 统一的同步决策逻辑 (`decideSyncAction`)
  - Vector Clock 更新 (`updateForLocalChange`)
  - Vector Clock 合并 (`mergeVectorClocks`)
  - Vector Clock 迁移 (`migrateVectorClock`)
  - Vector Clock 删除 (`deleteVectorClock`)
  - Vector Clock 保存和获取 (`saveVectorClock`, `getVectorClock`)

### 2. 重构 SyncEngine ✅
- `downloadAction` 函数已使用 `VectorClockManager.decideSyncAction`
- 重命名时的 Vector Clock 迁移已使用 `VectorClockManager.migrateVectorClock`
- 文件删除时的 Vector Clock 删除已使用 `VectorClockManager.deleteVectorClock`

### 3. 重构 FileTransfer ✅
- 下载文件时的 Vector Clock 合并已使用 `VectorClockManager.mergeVectorClocks`
- 上传文件时的 Vector Clock 更新已使用 `VectorClockManager.updateForLocalChange`
- Vector Clock 保存已使用 `VectorClockManager.saveVectorClock`

### 4. 重构 SyncManager ✅
- 接收文件时的 Vector Clock 合并已使用 `VectorClockManager`
- 文件删除时的 Vector Clock 删除已使用 `VectorClockManager`

### 5. 重构 P2PHandlers ✅
- 接收文件时的 Vector Clock 合并已使用 `VectorClockManager`
- Vector Clock 保存已使用 `VectorClockManager`

## 需要手动修复的部分

### SyncEngine.swift 中的 shouldUpload 函数
- 位置：`Sources/FolderSync/App/SyncEngine.swift` 第 502-531 行
- 当前状态：仍使用旧的直接比较逻辑
- 需要替换为：使用 `VectorClockManager.decideSyncAction`

**建议的替换代码：**
```swift
/// 决定是否上传（使用 VectorClockManager 统一决策逻辑）
nonisolated func shouldUpload(local: FileMetadata, remote: FileMetadata?, path: String) -> Bool {
    let localVC = local.vectorClock
    let remoteVC = remote?.vectorClock
    let localHash = local.hash
    let remoteHash = remote?.hash ?? ""
    
    let decision = VectorClockManager.decideSyncAction(
        localVC: localVC,
        remoteVC: remoteVC,
        localHash: localHash,
        remoteHash: remoteHash,
        direction: .upload
    )
    
    switch decision {
    case .skip, .overwriteLocal:
        return false
    case .overwriteRemote:
        return true
    case .conflict:
        // 并发冲突在上层逻辑中单独处理（先保存远程版本为冲突文件，再上传本地版本）
        return false
    case .uncertain:
        // 没有可用的 Vector Clock：采用"本地优先"策略，使集群最终收敛到本地版本
        print("[SyncEngine] ⚠️ [shouldUpload] 缺少 Vector Clock，采用本地优先上传策略: 路径=\(path)")
        return true
    }
}
```

## 重构优势

1. **逻辑集中化**：所有 Vector Clock 的处理逻辑都集中在 `VectorClockManager` 中，便于维护和测试
2. **一致性**：所有地方使用相同的决策逻辑，确保行为一致
3. **可测试性**：`VectorClockManager` 的静态方法易于单元测试
4. **可读性**：代码意图更清晰，减少了重复代码
5. **可维护性**：如果需要修改 Vector Clock 的处理逻辑，只需要修改 `VectorClockManager` 即可

## 注意事项

1. `VectorClockManager` 的所有方法都是静态方法，不需要实例化
2. `decideSyncAction` 方法会根据 `direction` 参数返回相应的决策结果
3. 对于 `uncertain` 情况（缺少 Vector Clock），下载方向保守处理为冲突，上传方向采用"本地优先"策略
4. Vector Clock 的合并遵循"取最大值"原则，确保保留所有历史信息
