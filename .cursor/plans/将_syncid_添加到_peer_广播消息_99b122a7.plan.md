---
name: 将 syncID 添加到 peer 广播消息
overview: 修改 LAN 发现机制，将 syncID 列表添加到 peer 广播消息中，使设备在发现 peer 时即可知道哪些 syncID 匹配，避免无效连接和死循环问题。
todos:
  - id: modify-broadcast-format
    content: 修改 LANDiscovery.createDiscoveryMessage 方法，添加 syncIDs 参数并更新 JSON 格式
    status: completed
  - id: modify-parse-logic
    content: 修改 LANDiscovery.parseDiscoveryMessage 方法，解析 syncIDs 字段并更新返回类型
    status: completed
  - id: update-lan-discovery-interface
    content: 修改 LANDiscovery 类，添加 syncIDs 存储和更新方法
    status: completed
  - id: modify-p2pnode-callback
    content: 修改 P2PNode 的 onPeerDiscovered 回调，传递 syncIDs 信息
    status: completed
  - id: update-syncmanager-discovery
    content: 修改 SyncManager 的 peerDiscoveryTask，利用 syncIDs 提前过滤
    status: completed
  - id: add-syncid-update-mechanism
    content: 在 SyncManager 中添加机制，在文件夹变化时更新广播中的 syncID
    status: completed
  - id: test-empty-syncids
    content: 测试空 syncID 列表的处理（新设备无文件夹时）
    status: completed
isProject: false
---

# 将 syncID 添加到 peer 广播消息的实施计划

## 目标

将 syncID 列表添加到 UDP 广播消息中，使设备在发现 peer 时即可知道哪些 syncID 匹配，从而：

- 避免对不匹配的 syncID 进行无效连接尝试
- 解决死循环问题
- 提升同步发现速度
- 减少网络请求和日志噪音

## 架构变更

### 当前流程

```
LANDiscovery 广播 → 发现 peer → 尝试所有 syncID → getMST 验证 → 匹配/不匹配
```

### 新流程

```
LANDiscovery 广播(含 syncID) → 发现 peer → 检查 syncID 匹配 → 只同步匹配的 syncID
```

## 实施步骤

### 1. 修改广播消息格式

**文件**: `Sources/FolderSync/Core/Networking/LANDiscovery.swift`

- 修改 `createDiscoveryMessage` 方法，添加必需的 `syncIDs` 参数
- 新格式：`{"peerID":"...","service":"foldersync","addresses":[...],"syncIDs":["id1","id2",...]}`
- 如果 `syncIDs` 为空，广播空数组 `[]`
- 限制 syncID 数量：最多包含前 20 个 syncID（避免消息过大）

### 2. 修改消息解析逻辑

**文件**: `Sources/FolderSync/Core/Networking/LANDiscovery.swift`

- 修改 `parseDiscoveryMessage` 方法，解析必需的 `syncIDs` 字段
- 返回类型改为：`(peerID: String, service: String, addresses: [String], syncIDs: [String])`
- 如果消息中没有 `syncIDs` 字段，返回空数组 `[]`（而不是 nil）

### 3. 修改 LANDiscovery 接口

**文件**: `Sources/FolderSync/Core/Networking/LANDiscovery.swift`

- 添加 `syncIDs` 属性用于存储当前设备的 syncID 列表
- 修改 `start` 方法签名：`start(peerID: String, listenAddresses: [String], syncIDs: [String])`
- 修改 `updateListenAddresses` 方法，添加 `updateSyncIDs` 方法
- 修改 `sendBroadcast` 方法，使用存储的 syncIDs

### 4. 修改 P2PNode 以传递 syncID

**文件**: `Sources/FolderSync/Core/Networking/P2PNode.swift`

- 添加对 SyncManager 的弱引用（通过回调或属性）
- 修改 `setupLANDiscovery` 方法，传递 syncID 列表
- 添加方法更新广播中的 syncID：`updateBroadcastSyncIDs(_ syncIDs: [String])`
- 在 IP 地址更新时也更新 syncID

### 5. 修改 SyncManager 以提供 syncID

**文件**: `Sources/FolderSync/App/SyncManager.swift`

- 在初始化 P2PNode 后，设置 syncID 更新回调
- 添加方法：`updateBroadcastSyncIDs()` 用于获取当前所有 syncID 并更新广播
- 在 `addFolder` 和 `removeFolder` 时调用更新方法
- 在初始化时调用一次，确保启动时广播包含 syncID

### 6. 修改 peer 发现处理逻辑

**文件**: `Sources/FolderSync/App/SyncManager.swift` (peerDiscoveryTask)

- 修改 `onPeerDiscovered` 回调，接收 syncIDs 参数
- 在触发同步前，检查远程设备的 syncID 列表
- 只对匹配的 syncID 触发同步，跳过不匹配的
- 记录日志：显示匹配的 syncID 数量

### 7. 修改 P2PNode 的 peer 发现回调

**文件**: `Sources/FolderSync/Core/Networking/P2PNode.swift`

- 修改 `onPeerDiscovered` 回调签名，包含 syncIDs 参数
- 修改 `handleDiscoveredPeer` 方法，传递 syncIDs 信息
- 更新 `onPeerDiscovered` 调用处，传递解析得到的 syncIDs

### 8. 移除或简化冷却期逻辑

**文件**: `Sources/FolderSync/App/SyncEngine.swift`

- 由于提前过滤，syncID 不匹配的情况会大幅减少
- 可以保留冷却期作为额外保护，但主要依赖广播中的 syncID 过滤

## 消息大小控制

- 限制最多 20 个 syncID（约 +200 bytes）
- 如果 syncID 过多，只广播前 20 个
- 总消息大小控制在 500 bytes 以内（UDP 安全范围）

## 测试要点

1. 验证广播消息包含 syncID
2. 验证只对匹配的 syncID 触发同步
3. 验证添加/删除文件夹时广播更新
4. 验证消息大小在安全范围内
5. 验证空 syncID 列表的处理（新设备无文件夹时）

## 文件修改清单

1. `Sources/FolderSync/Core/Networking/LANDiscovery.swift` - 广播消息格式和解析
2. `Sources/FolderSync/Core/Networking/P2PNode.swift` - syncID 传递和更新
3. `Sources/FolderSync/App/SyncManager.swift` - syncID 提供和过滤逻辑
4. `Sources/FolderSync/App/SyncManagerFolderManager.swift` - 文件夹变化时更新广播
5. `Sources/FolderSync/App/SyncEngine.swift` - 可选：简化冷却期逻辑

## 预期效果

- 消除死循环：不再对不匹配的 syncID 频繁重试
- 减少网络请求：避免无效的 getMST 请求
- 提升性能：提前过滤，减少 CPU 和网络开销
- 改善用户体验：更快发现可同步的设备

