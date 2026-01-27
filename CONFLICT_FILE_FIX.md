# 冲突文件无限循环问题修复

## 问题描述

在多端同步过程中，出现了大量冲突文件，文件名格式如：
```
文件名.conflict.{peerID1}.{timestamp1}.conflict.{peerID2}.{timestamp2}.扩展名
```

这些冲突文件本身也被同步，导致冲突文件不断产生新的冲突文件，形成无限循环，造成多端不停地同步文件。

## 根本原因

冲突文件在创建后，没有被排除在同步流程之外：
1. `FolderStatistics.calculateFullState` 计算本地文件列表时，包含了冲突文件
2. `SyncEngine` 的下载和上传阶段，没有过滤冲突文件
3. 发送给远程的文件列表，包含了冲突文件
4. 本地文件变更监听，没有排除冲突文件

## 解决方案

创建了 `ConflictFileFilter` 类来统一处理冲突文件的识别和过滤：

### 1. 冲突文件识别

冲突文件的命名格式：`文件名.conflict.{peerID}.{timestamp}.扩展名`

通过检查文件名是否包含 `.conflict.` 来判断是否为冲突文件。

### 2. 过滤位置

在以下位置添加了冲突文件过滤：

1. **`FolderStatistics.calculateFullState`**：计算本地文件状态时排除冲突文件
2. **`SyncEngine.performSync`**：
   - 获取远程文件列表后过滤冲突文件
   - 下载阶段排除冲突文件
   - 上传阶段排除冲突文件
3. **`P2PHandlers.handleSyncRequest`**：发送文件列表给远程时过滤冲突文件
4. **`SyncManager.recordLocalChange`**：本地文件变更监听时忽略冲突文件

### 3. 代码变更

#### 新增文件
- `Sources/FolderSync/Core/ConflictFileFilter.swift`：冲突文件过滤器类

#### 修改文件
- `Sources/FolderSync/App/FolderStatistics.swift`：在文件枚举时排除冲突文件
- `Sources/FolderSync/App/SyncEngine.swift`：在同步流程中过滤冲突文件
- `Sources/FolderSync/App/P2PHandlers.swift`：在发送文件列表时过滤冲突文件
- `Sources/FolderSync/App/SyncManager.swift`：在本地变更监听时忽略冲突文件

## 效果

修复后，冲突文件将：
- ✅ 不会被包含在文件列表中
- ✅ 不会被同步到其他设备
- ✅ 不会被本地变更监听触发同步
- ✅ 不会产生新的冲突文件

冲突文件将保留在本地，供用户手动处理，但不会参与自动同步流程。

## 注意事项

1. **现有冲突文件**：已存在的冲突文件不会自动删除，需要用户手动处理
2. **冲突文件管理**：冲突文件仍然可以通过 `ConflictCenter` UI 进行查看和管理
3. **Vector Clock**：冲突文件不会更新 Vector Clock，因为它们不参与同步

## 测试建议

1. 创建冲突文件，验证不会被同步
2. 在多端同时修改同一文件，验证冲突文件只创建一次
3. 验证冲突文件不会产生嵌套冲突（`.conflict.xxx.conflict.yyy`）
