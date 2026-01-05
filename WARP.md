# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## 常用命令

所有命令默认在仓库根目录（`FolderSync`）下执行。

### 构建应用

- **构建 Mac（Mac Catalyst）版本**
  ```bash
  dotnet build src/FolderSync.App/FolderSync.App.csproj -f net10.0-maccatalyst
  ```

- **构建 Windows 版本**（需安装对应 Windows 目标框架）
  ```bash
  dotnet build src/FolderSync.App/FolderSync.App.csproj -f net10.0-windows10.0.19041.0
  ```

- **发布发布版安装包**（来源：`docs/DeploymentGuide_EN.md`）
  ```bash
  # MacOS 发布
  dotnet publish src/FolderSync.App/FolderSync.App.csproj -f net10.0-maccatalyst -c Release -p:CreatePackage=true

  # Windows 发布
  dotnet publish src/FolderSync.App/FolderSync.App.csproj -f net10.0-windows10.0.19041.0 -c Release
  ```

### 测试

解决方案使用 xUnit，测试工程位于 `tests/FolderSync.Tests`。

- **运行全部测试**
  ```bash
  dotnet test tests/FolderSync.Tests/FolderSync.Tests.csproj
  ```

- **运行单个测试类或方法**（示例：`SyncQueueTests.Dequeue_ReturnsHighPriorityFirst`）
  ```bash
  dotnet test tests/FolderSync.Tests/FolderSync.Tests.csproj \
    --filter "FullyQualifiedName~FolderSync.Tests.SyncQueueTests.Dequeue_ReturnsHighPriorityFirst"
  ```

### 代码检查 / 格式化

仓库内没有单独的代码规范配置，可以依赖 .NET SDK 自带分析器（通过 `dotnet build`），必要时对项目运行：

```bash
dotnet format src/FolderSync.App/FolderSync.App.csproj
```

---

## 高层架构概览

FolderSync 是基于 .NET 10 与 .NET MAUI 的跨平台 P2P 文件同步应用。代码按分层架构组织在 `src/` 下的多个项目中，并配有 `tests/` 下的单元测试工程。

### 各项目职责

- **`src/FolderSync.App`（UI + 组合根）**
  - .NET MAUI 前端应用，XAML 页与视图模型位于 `*.xaml` 与 `ViewModels/` 下。
  - `MauiProgram.cs` 作为依赖注入组合根，集中注册 EF Core、加密、P2P 网络、同步引擎、平台服务以及所有页面/视图模型。
  - `MainViewModel` 是主面板视图模型，暴露 `SyncFolders` 和 `DiscoveredPeers`，订阅 `IPeerService.PeerDiscovered` 与 `IFileTransferService.TransferProgress` 事件以更新 UI 状态。
  - `HistoryPage`、`VersionsPage`、`ConflictsPage`、`PeersPage`、`SettingsPage` 等页面本身较薄，大部分业务逻辑在对应的 ViewModel 中完成，并通过接口与同步层和数据层交互。

- **`src/FolderSync.Core`（共享契约与模型）**
  - `Interfaces/` 定义核心抽象，例如：`IAuthenticationService`、`IEncryptionService`、`IFileTransferService`、`IHashService`、`INatService`、`INotificationService`、`IPeerService`、`IPlatformService`、`ISecureStorage` 等，供 App、Sync、P2P、Security、Data 各层依赖。
  - `Models/Messages/` 定义所有 P2P 控制消息 DTO：`HandshakeMessage`、`SyncMetaMessage`、`FileRequestMessage`、`QuickSendMessage`、`PairingRequestMessage`、`PairingResponseMessage` 以及用于同步引擎的 `FileDelta`。
  - `Resources/AppResources*.resx` 存放中英文本地化字符串，由应用层的本地化服务消费。

- **`src/FolderSync.Data`（持久化层）**
  - `FolderSyncDbContext`（EF Core）定义主要实体集合：
    - `ClientIdentity`：本机身份与凭据；
    - `SyncConfiguration`：每个同步目录的配置（过滤规则、优先级、时间窗口等）；
    - `FileMetadata`：文件哈希、大小、时间戳、删除状态等元数据；
    - `FileVersion`：历史版本归档；
    - `SyncHistory`：同步操作审计日志；
    - `PeerDevice`：已知设备及其信任状态、访问级别；
    - `SyncConflict`：冲突记录。
  - 在 `OnModelCreating` 中配置了关键索引与关系，例如：`SyncConfigId + FilePath` 唯一索引、版本号唯一约束等。
  - SQLite 数据库默认路径（见 `docs/DeploymentGuide_EN.md`）：
    - Mac：`~/Library/Application Support/FolderSync/foldersync.db`
    - Windows：`%AppData%\Local\FolderSync\foldersync.db`

- **`src/FolderSync.Security`（加密与异常检测）**
  - `HashService` 提供基于 SHA-256 的文件哈希计算，用于变更检测与完整性校验。
  - `EncryptionService` 提供 AES-256 加密流，`FileTransferService` 基于此实现端到端加密传输（使用 PBKDF2 派生密钥）。
  - `AnomalyDetectionService` 记录并检测异常行为（例如短时间高频删除），`SyncCoordinator` 订阅其事件并通过通知服务提示用户。

- **`src/FolderSync.P2P`（网络层）**
  - `PeerService` 使用 NetMQ 实现 `IPeerService`：
    - 通过 `NetMQBeacon` 在默认端口 `5000` 上进行局域网广播发现；
    - 在 `port + 1`（默认为 `5001`）上绑定 `RouterSocket` 接收控制消息；
    - 发现新节点时触发 `PeerDiscovered` 事件，收到消息时触发 `MessageReceived` 事件；
    - 提供 `SendMessageAsync`（向所有在线节点广播）和 `SendToPeerAsync`（指定 IP/端口发送）。
  - `NatService` 基于 Open.NAT：
    - 自动发现支持 UPnP 的路由器；
    - 创建/删除消息端口与文件传输端口的映射，尽可能实现 NAT 穿透。

- **`src/FolderSync.Sync`（同步引擎与后台服务）**
  - `SyncEngine`：
    - 订阅 `IFileMonitorService` 的文件变更事件；
    - 使用 JSON 序列化的 `SyncFilter` 规则（如忽略 `.DS_Store`、临时文件等）决定是否同步；
    - 对变更文件计算哈希（`IHashService`），更新或创建 `FileMetadata`；
    - 通过 `IVersionManager` 创建历史版本，并写入 `SyncHistory`；
    - 触发 `MetadataChanged` 事件，携带 `FileDelta` 作为对外同步元数据。
  - `SyncCoordinator`：
    - 是整个同步流程的中枢，连接 `IPeerService`、`ISyncEngine`、`IFileTransferService`、`INatService`、`INotificationService`、`IHashService`、`ICleanupService`、`IDiskMonitorService`、`ISyncQueue` 与 `IAnomalyDetectionService`；
    - 订阅 `ISyncEngine.MetadataChanged`，将本地变更包装为 `SyncMetaMessage` 通过 `IPeerService` 广播；
    - 订阅 `IPeerService.MessageReceived`，按消息类型分派到 `HandleHandshakeAsync`、`HandleSyncMetaAsync`、`HandleFileRequestAsync`、`HandleQuickSendAsync`、`HandlePairingRequestAsync`、`HandlePairingResponseAsync`；
    - 订阅 `IFileTransferService.FileReceived`，在文件接收完成后进行冲突检测、写入本地文件系统并更新数据库；
    - 订阅 `IDiskMonitorService.LowDiskSpaceDetected` 与 `IAnomalyDetectionService.AnomalyDetected`，通过通知服务展示告警；
    - 维护一个 `ISyncQueue`，启动多个后台工作线程从队列中取出 `SyncTask` 并下发实际下载请求；
    - 通过 `INatService` 在启动时映射消息端口（`5001`）与传输端口（`5002`），停止时解除映射。
  - `FileTransferService`：
    - 在默认 TCP 端口 `5002` 上监听文件传入；
    - 发送文件时：
      - 计算文件哈希并构造 `FileTransferMetadata`；
      - 按 `[4字节长度][JSON 元数据][加密后（可选 GZip 压缩）的文件字节流]` 格式发送；
      - 根据文件类型决定是否压缩；
      - 支持断点续传（通过偏移量 `Offset`/`RequestedOffset`）。
    - 接收文件时：
      - 先通过解密流解包，再根据 `UseCompression` 判断是否经由 GZip 解压；
      - 写入系统临时目录下的 `.part` 文件；
      - 校验哈希通过后触发 `FileReceived` 事件交由 `SyncCoordinator` 处理。
  - 其他服务：
    - `FileMonitorService`（未在此文件中）包装 OS 文件监控，并以 `FileChangedEventArgs` 形式通知 `SyncEngine`；
    - `VersionManager` 将旧版本存入隐藏目录 `.sync/versions`，并限制最大保留数量（默认 10 个版本）；
    - `ConflictService` 生成冲突文件路径并写入 `SyncConflict` 记录；
    - `CleanupService` 周期性清理旧的 `SyncHistory` 记录与过期的 `.part` 临时文件（默认每 24 小时一次，见部署文档）；
    - `DiskMonitorService` 定期检查磁盘空间并触发低空间告警。

- **`tests/FolderSync.Tests`（单元测试）**
  - 基于 xUnit 的测试工程，用于验证同步层的关键行为：
    - `SyncQueueTests`：校验同步队列按优先级出队；
    - `ConflictServiceTests`：验证冲突文件命名格式；
    - `VersionManagerTests`：在内存 SQLite 上验证版本归档逻辑与文件落盘。

### 端到端同步与 Quick Send 流程

1. **添加同步目录与开始监控**
   - 用户在 UI 中添加同步文件夹；`MainViewModel.AddFolderAsync` 调用 `ISyncEngine.AddSyncFolderAsync`；
   - `SyncEngine` 为该路径创建 `SyncConfiguration` 记录（包含默认 `SyncFilter`），启动 `FileMonitorService` 对该目录监控，并异步执行首次全量扫描，将既有文件以“模拟变更”的方式写入数据库。

2. **本地变更 → 元数据更新**
   - 当文件发生新增/修改/删除时，`FileMonitorService` 触发 `FileChangedEventArgs`；
   - `SyncEngine` 根据路径找到所属的 `SyncConfiguration`，应用过滤规则与大小限制；
   - 对存在的文件计算哈希并更新/新建 `FileMetadata`，记录 `SyncHistory`，并通过 `IVersionManager` 归档旧版本；
   - 同时触发 `MetadataChanged` 事件，携带 `FileDelta`（包含相对路径、哈希、大小、是否删除）。

3. **元数据向其他节点广播**
   - `SyncCoordinator` 监听 `MetadataChanged`，把每个 `FileDelta` 封装进 `SyncMetaMessage`，并通过 `IPeerService.SendMessageAsync` 使用 NetMQ 广播到所有在线节点；
   - 远端节点在各自的 `SyncCoordinator.HandleSyncMetaAsync` 中解析消息，根据本地数据库中的 `PeerDevice` 记录判断对端设备是否被信任/只读/阻止，并结合 `SyncConfiguration.IsInScheduleWindow()`（同步时间窗口）决定是否入队实际下载任务。

4. **队列处理与文件请求**
   - `SyncCoordinator.ProcessQueueAsync` 后台循环从 `ISyncQueue` 中取出 `SyncTask`；
   - 对于下载任务，构造 `FileRequestMessage`（携带期望哈希与续传偏移量），通过 `IPeerService.SendToPeerAsync` 发送到源节点的消息端口 `5001`。

5. **文件传输**
   - 发送端在 `HandleFileRequestAsync` 中根据 `FileRequestMessage.FilePath` 与本地 `FileMetadata/SyncConfiguration` 拼出绝对路径，并调用 `FileTransferService.SendFileAsync`，目标端口为 `5002`；
   - 接收端的 `FileTransferService` 在监听端口接收加密（及可选压缩）数据流，写入临时 `.part` 文件，完成后校验哈希并触发 `FileReceived`。

6. **应用收到的文件与冲突处理**
   - `SyncCoordinator.OnFileReceived` 查找当前启用的 `SyncConfiguration` 并构造目标路径；
   - 如果目标文件已存在，则根据数据库中的 `FileMetadata` 计算并比对本地当前哈希：
     - 若哈希不一致，视为冲突，调用 `ConflictService.GetConflictPath` 生成冲突文件路径，写入 `SyncConflict` 记录，并通过通知提示用户；
     - 若哈希一致，则直接覆盖/创建目标文件；
   - 然后更新 `FileMetadata` 并追加一条 `SyncHistory` 记录，用于后续审计和调试。

7. **Quick Send（快速单次传输）**
   - 一次性快速传输通过 `QuickSendMessage` 及 `FileTransferMetadata.IsQuickSend` 建模；
   - `SyncCoordinator.HandleQuickSendAsync` 自动为目标节点入队一个高优先级 `SyncTask`；
   - 文件到达后，`HandleQuickSendFileReceivedAsync` 将文件移动到用户主目录下的 `Downloads/FolderSync` 目录，并发出完成通知。

### 网络端口与 NAT

- 发现与消息（通过 `PeerService`）：
  - Beacon：`5000`（广播 `<DeviceName>:<DeviceId>:<responsePort>`）；
  - RouterSocket（控制消息监听）：`5001`（`port + 1`）。
- 文件传输（通过 `FileTransferService`）：
  - 默认 TCP 端口：`5002`（`port + 2`）。
- `NatService` 会尝试通过 UPnP 映射消息端口与文件传输端口，以便在支持 UPnP 的路由器后仍可互联。

### 安全与信任模型

- 所有文件传输均使用 AES-256 加密，并通过 PBKDF2 派生密钥，使用 SHA-256 哈希进行完整性校验；
- 设备信任与权限通过 `PeerDevice` 实体建模：
  - 设备可以是“未信任、已信任或已阻止”，访问级别如 `ReadOnly`、`Blocked` 会影响远端元数据是否能触发本地变更（尤其是删除）；
- `AnomalyDetectionService` 记录并上报可疑操作模式（如批量删除），`SyncCoordinator` 通过通知服务向用户展示；
- 应用支持可选 PIN 码锁定设置界面和设备管理，同时将敏感配置存储在本地 SQLite 数据库中（结合加密服务进行保护）。
