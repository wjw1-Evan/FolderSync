# 删除文件被同步回来 Bug 修复（第二次）

## 问题描述

删除的文件又被自动同步回来了。从终端日志可以看到：
- 大量 "VectorClock 相等但哈希不同，视为冲突" 的警告
- 这些文件被创建为冲突文件并下载
- 但实际上这些文件可能已经被删除

## 根本原因

1. **删除记录检查时机问题**：
   - `downloadAction` 函数在检查删除记录之前就进行了 Vector Clock 比较
   - 当 Vector Clock 相等但哈希不同时，会返回 `.conflict`，导致文件被下载
   - 即使文件在 `deletedSet` 中，也会因为冲突检测而下载

2. **删除记录清理逻辑问题**：
   - 删除记录在文件不在远程文件列表中时就被清理
   - 但如果另一个客户端还保留着这个文件，当它上线时可能会上传，导致文件被重新同步

## 修复方案

### 1. 在 downloadAction 中优先检查删除记录

在 `downloadAction` 函数中，**首先**检查文件是否在 `deletedSet` 中，如果是，直接返回 `.skip`，不进行 Vector Clock 比较：

```swift
func downloadAction(remote: FileMetadata, local: FileMetadata?, path: String) -> DownloadAction {
    // 重要：如果文件已删除（在 deletedSet 中），直接跳过，不下载
    // 这可以防止已删除的文件因为 Vector Clock 相等但哈希不同而被重新下载
    if deletedSet.contains(path) {
        print("[SyncEngine] ⏭️ [downloadAction] 文件已删除，跳过下载: 路径=\(path)")
        return .skip
    }
    
    // ... 后续的 Vector Clock 比较逻辑
}
```

### 2. 在下载阶段再次检查删除记录

在调用 `downloadAction` 之前，再次检查删除记录，并在冲突处理时也检查：

```swift
// 再次检查删除记录（在 downloadAction 调用之前）
if deletedSet.contains(path) {
    print("[SyncEngine] ⏭️ [download] 文件已删除，跳过下载: 路径=\(path)")
    continue
}

switch downloadAction(remote: remoteMeta, local: localMetadata[path], path: path) {
case .skip: break
case .overwrite:
    changedFilesSet.insert(path)
    changedFiles.append((path, remoteMeta))
case .conflict:
    // 重要：即使检测到冲突，如果文件已删除，也不应该创建冲突文件
    if deletedSet.contains(path) {
        print("[SyncEngine] ⏭️ [download] 冲突但文件已删除，跳过: 路径=\(path)")
        continue
    }
    conflictFilesSet.insert(path)
    conflictFiles.append((path, remoteMeta))
}
```

### 3. 改进删除记录清理逻辑

删除记录的清理逻辑保持不变，但添加了更详细的注释说明：

- 只有当文件不在远程文件列表中时，才认为删除已确认
- 远程文件列表是权威的：如果文件不在列表中，说明文件已不存在
- 无论是否在远程删除记录中，只要文件不在远程文件列表中，就可以确认删除

## 修复效果

1. ✅ **防止已删除文件被下载**：在 `downloadAction` 中优先检查删除记录
2. ✅ **防止冲突文件创建**：即使检测到冲突，如果文件已删除，也不创建冲突文件
3. ✅ **双重检查**：在下载阶段和 `downloadAction` 中都检查删除记录，确保万无一失

## 代码变更

- **修改文件**：`Sources/FolderSync/App/SyncEngine.swift`
  - 第 475-512 行：在 `downloadAction` 中优先检查删除记录
  - 第 622-633 行：在下载阶段再次检查删除记录，并在冲突处理时也检查

## 注意事项

1. **删除记录优先级**：删除记录的检查应该在 Vector Clock 比较之前进行
2. **冲突处理**：即使检测到冲突，如果文件已删除，也不应该创建冲突文件
3. **双重检查**：在多个位置检查删除记录，确保已删除的文件不会被重新下载
