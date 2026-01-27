# 冲突检测功能修复

## 问题描述

冲突检测功能存在以下问题：

1. **双重冲突检测逻辑不一致**：
   - 上传阶段有手动冲突检测（只检测 `concurrent` 情况）
   - 同时调用 `shouldUpload` 函数（使用 `VectorClockManager.decideSyncAction` 检测所有冲突类型）
   - 手动检测可能遗漏某些冲突情况（如 `equal` 但哈希不同）

2. **冲突检测不完整**：
   - 手动检测只检查 `concurrent` 情况
   - `VectorClockManager.decideSyncAction` 还会检测 `equal` 但哈希不同的情况
   - 某些冲突可能被遗漏

3. **处理逻辑不统一**：
   - 下载冲突通过 `downloadAction` 统一处理
   - 上传冲突有手动检测和 `shouldUpload` 两套逻辑

## 修复方案

### 1. 统一使用 VectorClockManager.decideSyncAction

在上传阶段，移除手动冲突检测，统一使用 `VectorClockManager.decideSyncAction` 进行决策：

```swift
// 统一使用 VectorClockManager 检测冲突（包括并发冲突和 equal 但哈希不同的情况）
let remoteMeta = remoteEntries[path]
let decision = VectorClockManager.decideSyncAction(
    localVC: localMeta.vectorClock,
    remoteVC: remoteMeta?.vectorClock,
    localHash: localMeta.hash,
    remoteHash: remoteMeta?.hash ?? "",
    direction: .upload
)

switch decision {
case .skip, .overwriteLocal:
    // 不需要上传
    break
case .overwriteRemote:
    // 需要上传覆盖远程
    filesToUploadSet.insert(path)
    filesToUpload.append((path, localMeta))
case .conflict:
    // 冲突：需要先保存远程版本为冲突文件，然后再上传本地版本
    if let remoteMeta = remoteMeta {
        uploadConflictFiles.append((path, remoteMeta))
        filesToUploadSet.insert(path)
        filesToUpload.append((path, localMeta))
    } else {
        // 没有远程元数据，但检测到冲突（可能是 equal 但哈希不同），直接上传
        filesToUploadSet.insert(path)
        filesToUpload.append((path, localMeta))
    }
case .uncertain:
    // 无法确定：采用本地优先策略
    filesToUploadSet.insert(path)
    filesToUpload.append((path, localMeta))
}
```

### 2. 保留 shouldUpload 函数用于 FileTransfer

`shouldUpload` 函数保留用于 `FileTransfer` 等需要简单布尔判断的场景，但添加了注释说明冲突在上层统一处理。

### 3. 确保冲突处理一致性

- **下载冲突**：通过 `downloadAction` → `VectorClockManager.decideSyncAction` → 返回 `.conflict` → 保存为冲突文件
- **上传冲突**：通过 `VectorClockManager.decideSyncAction` → 返回 `.conflict` → 先保存远程版本为冲突文件，再上传本地版本

## 修复效果

1. ✅ **统一冲突检测**：所有冲突检测都通过 `VectorClockManager.decideSyncAction` 进行
2. ✅ **完整冲突检测**：检测所有冲突类型（`concurrent` 和 `equal` 但哈希不同）
3. ✅ **处理逻辑一致**：下载和上传的冲突处理逻辑统一
4. ✅ **避免遗漏**：不会因为手动检测的局限性而遗漏某些冲突情况

## 代码变更

- **修改文件**：`Sources/FolderSync/App/SyncEngine.swift`
  - 移除手动冲突检测逻辑（第 625-639 行）
  - 统一使用 `VectorClockManager.decideSyncAction` 进行决策
  - 更新 `shouldUpload` 函数注释

## 注意事项

1. **FileTransfer 兼容性**：`shouldUpload` 函数仍然保留，用于 `FileTransfer` 等场景
2. **冲突文件创建**：冲突文件的创建逻辑保持不变，仍然先保存远程版本，再上传本地版本
3. **Vector Clock 处理**：冲突文件的 Vector Clock 处理逻辑保持不变
