# FolderSync 测试套件

## 概述

本测试套件提供了完整的文件和文件夹多端同步测试，涵盖以下场景：

- **多端同步基础测试** (`MultiPeerSyncTests.swift`)
- **文件操作同步测试** (`FileOperationsSyncTests.swift`)
- **离线场景测试** (`OfflineSyncTests.swift`)
- **重新上线测试** (`ReconnectSyncTests.swift`)
- **冲突处理测试** (`ConflictResolutionTests.swift`)
- **边界情况测试** (`EdgeCasesTests.swift`)
- **同步逻辑优化测试** (`SyncOptimizationTests.swift`)：`calculateFullState` 多文件防死锁、`triggerSync` 预计算状态多 peer、块级同步 FastCDC 复用等

## 测试覆盖范围

### 文件操作
- ✅ 添加文件（单个、多个、文件夹）
- ✅ 修改文件（单个、多个、大文件）
- ✅ 删除文件（单个、多个、文件夹）
- ✅ 复制文件（单个、文件夹）
- ✅ 重命名文件（单个、文件夹、哈希值匹配检测）

### 在线/离线场景
- ✅ 离线添加文件
- ✅ 离线修改文件
- ✅ 离线删除文件（删除记录传播）
- ✅ 离线复制文件
- ✅ 离线重命名文件
- ✅ 多客户端离线场景
- ✅ 重新上线后同步
- ✅ 网络中断恢复

### 冲突处理
- ✅ 并发修改冲突
- ✅ 多客户端同时删除同一文件
- ✅ 添加-删除冲突
- ✅ 重命名-修改冲突
- ✅ 冲突文件不被同步

### 边界情况
- ✅ 空文件夹中添加文件
- ✅ 大文件同步（块级增量同步）
- ✅ 大文件修改（块级增量同步）
- ✅ 特殊字符文件名
- ✅ 超长文件名
- ✅ 深层嵌套文件夹
- ✅ 快速连续添加/修改
- ✅ 零字节文件
- ✅ 同名文件夹和文件
- ✅ 符号链接

## 运行测试

### 出现 "No matching test cases were run" / Executed 0 tests

若在 IDE 中运行「选中测试」时出现上述提示，通常是因为未选中具体测试或过滤器未匹配。请改用以下方式之一：

- **VS Code / Cursor**：命令面板 → **Tasks: Run Task** → 选择 **swift: Run All Tests**（运行全部测试）
- **终端**：在项目根目录执行 `swift test` 运行全部测试

### 使用 Swift Package Manager

```bash
# 运行所有测试
swift test

# 运行特定测试类
swift test --filter MultiPeerSyncTests
swift test --filter FileOperationsSyncTests
swift test --filter OfflineSyncTests
swift test --filter ReconnectSyncTests
swift test --filter ConflictResolutionTests
swift test --filter EdgeCasesTests
swift test --filter SyncOptimizationTests

# 运行特定测试方法
swift test --filter MultiPeerSyncTests.testMultipleClientsInitialization
```

### 使用 Xcode

1. 在 Xcode 中打开项目
2. 选择测试目标 `FolderSyncTests`
3. 按 `Cmd+U` 运行所有测试
4. 或点击测试方法旁边的播放按钮运行单个测试

## 测试环境要求

- macOS 14.0+
- Swift 5.9+
- 多个网络接口（用于模拟多客户端）或实际的多设备环境

## 注意事项

1. **网络环境**：某些测试需要实际的网络环境来模拟多客户端场景。如果测试失败，请检查网络连接。

2. **超时设置**：测试中使用了较长的等待时间（3-15秒）来确保同步完成。如果测试环境较慢，可能需要调整超时时间。

3. **临时文件**：测试使用临时目录，测试完成后会自动清理。如果测试中断，可能需要手动清理临时文件。

4. **并发测试**：某些测试涉及并发操作，结果可能因系统负载而有所不同。

5. **离线模拟**：离线场景通过停止 P2P 节点来模拟，这可能需要一些时间来生效。

## 测试辅助工具

`TestHelpers.swift` 提供了以下辅助功能：

- 临时目录管理（`createTempDirectory`、`cleanupTempDirectory`）
- 文件操作（`createTestFile`、`readFileContent`、`readFileData`、`fileExists`、`directoryExists`、`getAllFiles`）
- 同步完成等待（`waitForSyncCompletion`：synced/error 时立即返回，避免无效轮询）
- 显式触发同步并等待（`triggerSyncAndWait`）
- 条件等待（`waitForCondition`）
- 大文件数据生成（`generateLargeFileData`）
- 测试用 SyncFolder 创建（`createTestSyncFolder`）

## 故障排除

### 测试失败：客户端未发现

- 确保网络连接正常
- 增加等待时间
- 检查防火墙设置

### 测试失败：文件未同步

- 检查同步状态
- 增加同步等待时间
- 查看日志输出

### 测试失败：冲突文件未生成

- 确保操作真正并发
- 检查 Vector Clock 状态
- 查看冲突检测逻辑

## 贡献

添加新测试时，请遵循以下规范：

1. 使用 `TestHelpers` 中的辅助函数
2. 在 `setUp` 中初始化，在 `tearDown` 中清理
3. 使用合理的超时时间
4. 添加清晰的测试描述
5. 验证关键状态和内容
