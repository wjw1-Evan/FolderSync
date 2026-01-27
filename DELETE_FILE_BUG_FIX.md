# 删除文件被同步回来 Bug 修复

## 问题描述

删除的文件在下次同步时又被同步回来了。这是一个严重的同步一致性问题。

## 根本原因

在 `SyncEngine.swift` 第 699-704 行，删除请求成功（收到 `deleteAck`）后，代码立即从 `deletedSet` 中移除了这些文件：

```swift
if case .deleteAck = delRes {
    // 删除成功后，从 deletedSet 中移除这些文件
    for rel in toDelete {
        deletedSet.remove(rel)
        locallyDeleted.remove(rel)
        // ...
    }
}
```

**问题**：
1. `deleteAck` 只表示远程**收到了删除请求**，不一定表示文件已**真正删除**
2. 如果删除请求成功，但远程文件还在（比如远程还没处理完删除），那么：
   - `deletedSet` 中已经没有这个文件了
   - 下次同步时，在下载阶段（第 571 行）检查 `deletedSet.contains(path)` 会返回 `false`
   - 如果文件不在 `lastKnown` 中，或者 `lastKnown` 被清空，就会重新下载文件

## 修复方案

### 1. 删除请求成功后不立即移除 deletedSet

删除请求成功后，**不要**立即从 `deletedSet` 中移除文件，而是：
- 删除本地文件（如果存在）
- 删除 Vector Clock
- **保留** `deletedSet` 中的记录，直到下次同步时确认远程文件已不存在

### 2. 通过远程文件列表确认删除

在第 542-549 行，已经有正确的逻辑来确认删除：

```swift
// 清理已确认删除的文件（远程也没有了）
// 注意：如果文件在远程不存在，说明删除已经完成，从 deletedSet 中移除
let confirmed = deletedSet.filter { !remoteEntries.keys.contains($0) }
for p in confirmed {
    deletedSet.remove(p)
    locallyDeleted.remove(p)
    print("[SyncEngine] ✅ 删除已确认: \(p) (远程文件已不存在)")
}
```

这是删除确认的**唯一正确时机**：通过检查远程文件列表确认文件已不存在。

## 修复效果

1. ✅ **防止文件被重新下载**：删除请求成功后，文件仍然保留在 `deletedSet` 中，直到确认远程文件已不存在
2. ✅ **正确的删除确认**：只有通过检查远程文件列表确认文件已不存在后，才从 `deletedSet` 中移除
3. ✅ **保持一致性**：删除操作的一致性通过 `deletedSet` 和远程文件列表的双重检查来保证

## 代码变更

- **修改文件**：`Sources/FolderSync/App/SyncEngine.swift`
  - 第 699-742 行：删除请求成功后，不立即从 `deletedSet` 中移除
  - 第 542-549 行：添加日志，明确这是删除确认的唯一正确时机
  - 第 743-750 行：移除删除请求成功后的 `deletedPaths` 更新逻辑

## 注意事项

1. **删除确认时机**：删除确认的唯一正确时机是通过检查远程文件列表（第 542-549 行）
2. **deletedSet 持久化**：`deletedSet` 会通过 `syncManager.updateDeletedPaths` 持久化，确保应用重启后仍然有效
3. **多端同步**：这个修复确保了在多端同步场景下，删除操作的一致性
