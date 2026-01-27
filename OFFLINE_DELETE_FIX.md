# 离线客户端删除文件同步问题修复

## 问题描述

当删除文件时，如果某个客户端不在线，删除后该客户端上线了，被删除的文件就被同步回来了。这是一个严重的同步一致性问题。

**场景**：
1. 客户端A删除了文件，并发送删除请求给其他在线客户端
2. 客户端B不在线，没有收到删除请求
3. 客户端B上线后，同步时发现本地有文件，但远程（客户端A）没有这个文件
4. 客户端B可能会上传这个文件，导致已删除的文件被同步回来

## 根本原因

删除操作只通过 `deleteFiles` 请求发送给**在线**客户端，没有机制将删除记录（tombstones）传播给**不在线**的客户端。当不在线的客户端上线时，它不知道哪些文件已被删除。

## 修复方案

### 1. 在同步消息中添加删除记录交换

修改 `SyncResponse.files`，添加删除记录（tombstones）字段：

```swift
case files(syncID: String, entries: [String: FileMetadata], deletedPaths: [String] = [])
```

### 2. 在获取文件列表时发送删除记录

在 `P2PHandlers.handleSyncRequest` 中，当收到 `getFiles` 请求时，不仅返回文件列表，还返回本地的删除记录：

```swift
case .getFiles(let syncID):
    let folder = await MainActor.run { syncManager.folders.first(where: { $0.syncID == syncID }) }
    if let folder = folder {
        let (_, metadataRaw, _, _) = await folderStatistics.calculateFullState(for: folder)
        let metadata = ConflictFileFilter.filterConflictFiles(metadataRaw)
        // 获取本地的删除记录（tombstones），发送给远程客户端
        let deletedPaths = Array(syncManager.deletedPaths(for: syncID))
        return .files(syncID: syncID, entries: metadata, deletedPaths: deletedPaths)
    }
```

### 3. 在同步时处理远程的删除记录

在 `SyncEngine.performSync` 中，当收到远程文件列表时，同时处理远程的删除记录：

```swift
// 处理远程的删除记录（tombstones）
let remoteDeletedSet = Set(remoteDeletedPaths)
if !remoteDeletedSet.isEmpty {
    for deletedPath in remoteDeletedSet {
        // 如果本地有这个文件，删除它
        let fileURL = currentFolder.localPath.appendingPathComponent(deletedPath)
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: fileURL)
            VectorClockManager.deleteVectorClock(syncID: syncID, path: deletedPath)
        }
        // 更新 deletedSet，确保这个文件不会被上传
        deletedSet.insert(deletedPath)
    }
    // 更新持久化的删除记录
    syncManager.updateDeletedPaths(deletedSet, for: syncID)
}
```

### 4. 在上传时检查删除记录

在上传阶段，确保已删除的文件不会被上传：

```swift
// 跳过已删除的文件（包括本地删除和远程删除记录）
if locallyDeleted.contains(path) || deletedSet.contains(path) {
    continue
}
```

## 修复效果

1. ✅ **删除记录传播**：删除记录通过文件列表同步传播给所有客户端（包括不在线的）
2. ✅ **离线客户端同步**：当不在线的客户端上线时，会收到删除记录并删除本地文件
3. ✅ **防止重新上传**：已删除的文件不会被重新上传，即使客户端之前不在线
4. ✅ **一致性保证**：所有客户端最终都会删除相同的文件，保持一致性

## 代码变更

- **修改文件**：
  - `Sources/FolderSync/Models/SyncMessage.swift`：添加 `deletedPaths` 字段到 `files` 响应
  - `Sources/FolderSync/App/P2PHandlers.swift`：在 `getFiles` 响应中包含删除记录
  - `Sources/FolderSync/App/SyncEngine.swift`：处理远程删除记录并更新本地状态

## 工作流程

1. **客户端A删除文件**：
   - 检测到本地删除
   - 更新 `deletedPaths`
   - 发送删除请求给在线客户端

2. **客户端B不在线**：
   - 没有收到删除请求
   - 本地文件仍然存在

3. **客户端B上线并同步**：
   - 发送 `getFiles` 请求
   - 收到文件列表和删除记录
   - 根据删除记录删除本地文件
   - 更新本地的 `deletedPaths`

4. **客户端B后续同步**：
   - 检查 `deletedSet`，不会上传已删除的文件
   - 删除记录会传播给其他客户端

## 注意事项

1. **删除记录持久化**：删除记录会持久化到 `deletedRecords.json`，确保应用重启后仍然有效
2. **删除确认**：删除记录会在远程文件列表中确认（如果文件不在远程列表中，说明删除已完成）
3. **多端同步**：删除记录会在所有客户端之间传播，确保最终一致性
