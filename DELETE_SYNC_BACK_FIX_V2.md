# 删除文件被同步回来 Bug 修复（第二次）

## 问题描述

删除文件后，打开另一个客户端，删除的文件又同步回来了。这是一个严重的同步一致性问题。

**场景**：
1. 客户端A删除了文件，创建了删除记录
2. 客户端B不在线，没有收到删除记录
3. 客户端B上线后，同步时发现本地有文件，但远程（客户端A）没有这个文件
4. 客户端B可能会上传这个文件，导致已删除的文件被同步回来

## 根本原因分析

### 1. 删除记录传播问题
- 删除记录通过 `filesV2` 或 `files` 消息传播
- 但如果客户端B上线时，客户端A的删除记录可能还没有传播到客户端B
- 或者删除记录传播了，但在决策时没有正确检查

### 2. 上传决策问题
- 当本地有文件但远程没有状态时，`SyncDecisionEngine` 会返回 `.upload`
- 但这种情况可能意味着：
  1. 文件是新文件（应该上传）
  2. 文件已被删除但删除记录没有传播（不应该上传）

### 3. 删除记录检查时机问题
- 删除记录检查在上传决策之后
- 如果决策返回 `.upload`，即使有删除记录，文件也可能被上传

## 修复方案

### 1. 在上传和下载阶段先检查删除记录

**修复前**：
```swift
// 先使用决策引擎决策
let action = SyncDecisionEngine.decideSyncAction(...)
switch action {
case .upload:
    // 上传文件
}
```

**修复后**：
```swift
// 先检查删除记录
if deletedSet.contains(path) || remoteDeletedPaths.contains(path) {
    continue  // 跳过上传
}
// 再使用决策引擎决策
let action = SyncDecisionEngine.decideSyncAction(...)
```

### 2. 改进 SyncDecisionEngine 的决策逻辑

**修复前**：
```swift
if localState != nil && remoteState == nil {
    return .upload  // 直接返回上传
}
```

**修复后**：
```swift
if localState != nil && remoteState == nil {
    return .uncertain  // 返回不确定，让调用者根据删除记录决定
}
```

### 3. 确保删除记录正确传播

**修复**：
- 确保 `P2PHandlers` 总是返回删除记录（即使没有文件）
- 确保 `remoteDeletedPaths` 包含所有删除记录
- 在上传和下载阶段都检查 `remoteDeletedPaths`

### 4. 改进删除记录的 Vector Clock 比较逻辑

**修复前**：
```swift
case .antecedent:
    // 删除记录的 VC 更旧，上传本地文件（删除被覆盖）
    return .upload
```

**修复后**：
```swift
case .antecedent:
    // 删除记录的 VC 更旧，但保守处理为保持删除
    // 因为删除操作已经发生，不应该被覆盖
    return .skip
```

## 修复效果

1. ✅ **防止已删除文件被上传**：在上传阶段先检查删除记录
2. ✅ **防止已删除文件被下载**：在下载阶段先检查删除记录
3. ✅ **确保删除记录传播**：删除记录总是包含在同步消息中
4. ✅ **保守的删除处理**：删除操作不会被覆盖

## 代码变更

- **修改文件**：`Sources/FolderSync/App/SyncEngine.swift`
  - 第 736-744 行：在下载阶段先检查删除记录
  - 第 844-855 行：在上传阶段先检查删除记录
  - 第 723 行：合并所有路径时包含 `remoteDeletedPaths`
  - 第 826 行：合并所有路径时包含 `remoteDeletedPaths`

- **修改文件**：`Sources/FolderSync/Core/Sync/SyncDecisionEngine.swift`
  - 第 102-103 行：当本地有文件但远程没有状态时，返回 `.uncertain`
  - 第 87-88 行：删除记录的 VC 更旧时，保守处理为保持删除

- **修改文件**：`Sources/FolderSync/App/P2PHandlers.swift`
  - 第 72-78 行：确保删除记录总是包含在同步消息中

## 注意事项

1. **删除记录优先级**：删除记录的检查应该在决策之前进行
2. **双重检查**：在决策前后都检查删除记录，确保万无一失
3. **保守策略**：对于不确定的情况，采用保守策略，避免已删除文件被重新同步
