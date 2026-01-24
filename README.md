# macOS无服务器文件夹自动同步客户端设计方案（Swift）

# 一、项目概述

## 核心功能

**客户端之间文件自动同步**：实现多台 macOS 设备之间的文件夹自动同步，无需中央服务器。当一台设备上的文件发生变化时，其他设备会自动检测并同步更新，确保所有设备上的文件保持一致。

## 项目描述

本项目是一款基于 macOS 平台的客户端程序，采用 Swift 语言编写，通过 P2P（点对点）技术实现多台电脑之间文件夹的自动同步，全程无需依赖中央服务器。程序具备设备自动发现、实时文件监控、基于内容块的增量同步、端到端加密等核心功能，兼顾同步效率、数据安全与用户体验，适用于家庭、小型团队等场景下的多设备文件协同管理。

> 运行提示：局域网自动发现依赖 mDNS，现默认开启。若在特殊网络环境遇到崩溃或不希望广播，可设置环境变量 `FOLDERSYNC_ENABLE_MDNS=0` 禁用；需要发现时，请确保各客户端均开启 mDNS 并连接同一子网。

核心目标：
- **自动同步**：客户端之间自动检测文件变化并同步，无需手动操作
- **无服务器架构**：打破服务器依赖，实现设备间直连同步
- **多设备协作**：支持多设备同时在线协作
- **实时性**：通过 FSEvents 实时监控文件变化，快速同步
- **一致性**：通过 MST 和 Vector Clocks 保证文件同步的一致性
- **安全性**：端到端加密，确保数据传输安全
- **用户体验**：提供简洁直观的 macOS 原生 GUI 交互

# 二、核心技术选型

## 1. 开发环境与语言

- 开发语言：Swift 5.9+，利用Swift Concurrency（async/await）、Combine框架实现异步任务与事件驱动，适配macOS 14+系统版本。
- 开发工具：Xcode 15+，使用SwiftUI构建GUI。
- 依赖管理：Swift Package Manager (SPM)。

## 2. 核心技术模块

- **P2P通信 (libp2p)**：集成 **libp2p** 框架，利用其 mDNS 进行局域网发现，Kademlia DHT 进行广域网发现。通过 AutoNAT 和 Circuit Relay (v2) 解决复杂的 NAT 穿透问题，通过 Noise 协议保障传输安全。
- **系统集成 (ServiceManagement)**：利用 `ServiceManagement` 框架（`SMAppService`）实现用户可控的“开机自动启动”功能。
- **文件监控 (FSEvents)**：利用 macOS 原生 FSEvents API 实现高效的目录递归监控，捕获文件创建、修改、删除、重命名等事件。
- **增量同步 (CDC & Merkle Search Trees)**：
    - **内容定义切分 (CDC)**：使用 FastCDC 算法将文件切分为变长数据块，提高数据去重率并解决“插入/删除字节导致偏移失效”的问题。
    - **状态同步 (MST)**：使用 **Merkle Search Trees (MST)** 维护集群状态，通过对比树哈希在 $O(\log n)$ 时间内快速定位差异文件。
- **一致性与冲突处理**：使用 **Vector Clocks** 追踪文件变更的因果关系。冲突发生时，保留多版本（由用户手动或按策略自动解决），确保数据不丢失。
- **身份验证与配对 (Authentication & Pairing)**：
    - **设备身份**：每个设备在首次启动时生成随机 Ed25519 密钥对，PeerID 作为全球唯一标识。
    - **带外配对 (OOB Pairing)**：采用 **6 位数字配对码 (Short Authentication String)** 进行初次身份交换。用户在两台设备上核对显示的数字是否一致，确保“人机在场”安全性。
    - **Noise 手性协议**：基于 Noise Protocol Framework (XX 握手模式) 实现相互认证的加密信道。
- **加密机制**：采用端到端加密 (E2EE)，使用 Noise 协议加密传输链路，本地元数据加密存储在 macOS Keychain。

# 三、系统架构设计

## 1. 整体架构（分层设计）

采用 **单进程应用架构**，各层通过直接调用和 Swift Concurrency 进行通信：

1. **表现层 (SwiftUI Client)**：提供设备管理、同步文件夹配置、状态实时监控、冲突解决等界面。
2. **业务逻辑层 (Sync Engine)**：负责文件索引管理、因果追踪、冲突策略执行、同步任务调度。通过 `@MainActor` 和 `ObservableObject` 与 UI 层进行状态同步。
3. **网络层 (libp2p Wrapper)**：封装底层 P2P 逻辑，包括对等点发现、连接管理、多路复用与安全性保障。通过异步回调与业务逻辑层通信。
4. **存储层 (Metadata Storage)**：使用 SQLite (WAL mode) 存储文件索引、块信息、设备状态与同步日志。

## 2. 核心模块详解

### （1）网络与设备发现 (libp2p)
- **多协议发现**：mDNS 负责局域网，DHT/Bootstrap 节点辅助广域网。
- **自愈连接**：当网络环境变化时，AutoNAT 自动重新探测并尝试穿透，直连失败时自动启用可信 Relay。
- **对等点身份**：基于 Ed25519 密钥对生成 PeerID，作为设备唯一身份标识。

### （2）内容定义块管理 (Block Management)
- **FastCDC 算法**：已实现 FastCDC 算法用于文件内容定义切分，为未来的块级别同步优化做准备。
- **当前实现**：当前版本采用文件级别的同步，通过文件哈希对比快速识别需要同步的文件。
- **未来优化**：计划实现块级别的去重存储和增量传输，进一步提升大文件同步效率。

### （3）差分同步 (MST-based Diff)
- **增量列表同步**：相比全量发送文件列表，MST 仅在分支哈希不一致时递归向下探测，极大程度节省元数据交换带宽。

### （4）身份验证与信任管理
- **信任链同步**：已配对的设备列表在受信任集群内同步。
- **证书锁定 (Certificate Pinning)**：连接时强校验 PeerID 对应的公钥，防止中间人工具（MITM）劫持。
- **本地存储安全性**：私钥存储在 macOS Keychain 中，确保硬件级别的安全性。

# 四、GUI 界面设计

1. **仪表盘 (Dashboard)**：显示整体同步进度、实时上传/下载速度、连接对等点数量。
2. **文件夹管理中心**：
    - **多文件夹支持**：列表化管理多个同步文件夹。用户可为每个文件夹分配唯一的“同步 ID”，用于跨设备关联。
    - **选择性同步**：支持配置独立的排除规则（`.gitignore` 风格）及同步模式（双向/单向）。
3. **对等点视图**：展示已知设备列表，标记连接路径（直连/Relay）及同步偏移量。
4. **版本/冲突中心**：展示变更历史及需要手动介入的冲突文件。
5. **菜单栏常驻 (Menu Bar Extra)**：
    - 展示简要同步状态（如：✅ 已同步、⏳ 同步中...）。
    - 快速打开主窗口、手动触发同步、退出程序。
    - 进入“设置”开启/关闭“开机自动启动”。
6. **设备配对向导 (Pairing Wizard)**：
    - **发现模式**：展示本机 PeerID 指纹，并列出局域网内请求配对的邻居设备。
    - **验证码确认**：双端同步显示 6 位数字验证码（SAS），用户通过肉眼比对并点击“确认”完成绑定。
    - **手动添加**：支持输入远程设备的 PeerID 发起连接请求。

# 五、代码实现方案 (核心逻辑)

### （1）libp2p 节点初始化 (伪代码)
```swift
class P2PNode {
    private var host: Libp2pHost

    func start() async throws {
        let config = Libp2pConfig()
            .with(transport: .tcp, .quic)
            .with(discovery: .mdns, .dht)
            .with(security: .noise)

        self.host = try await Libp2p.create(config)
        await host.start()
    }
}
```

### （2）CDC 块切分逻辑
```swift
func processFileContent(url: URL) throws -> [BlockID] {
    let rawData = try Data(contentsOf: url)
    let chunks = FastCDC.chunk(data: rawData, min: 4KB, avg: 16KB, max: 64KB)
    return chunks.map { chunk in
        let id = SHA256.hash(data: chunk)
        Storage.shared.storeBlock(id: id, content: chunk)
        return id
    }
}
```

### （3）系统集成：菜单栏与开机启动
```swift
// 菜单栏定义
@main
struct FolderSyncApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
        }
        MenuBarExtra("FolderSync", systemImage: "arrow.triangle.2.circlepath") {
            Button("显示主界面") { /* 展示窗口 */ }
            Divider()
            Toggle("开机自动启动", isOn: $isLaunchAtLoginEnabled)
                .onChange(of: isLaunchAtLoginEnabled) { enabled in
                    toggleLaunchAtLogin(enabled)
                }
            Button("退出") { NSApplication.shared.terminate(nil) }
        }
    }
}

// 开机启动控制 (macOS 13+)
func toggleLaunchAtLogin(_ enabled: Bool) {
    let service = SMAppService.mainApp
    do {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    } catch {
        print("设置开机启动失败: \(error)")
    }
}
```

### （4）身份验证：基于 Noise 的握手与配对
```swift
// 配对码生成与校验逻辑
class PairingManager {
    static func generateSASCode() -> String {
        // 生成 6 位随机数字，用于带外确认 (Short Authentication String)
        return String(format: "%06d", UInt32.random(in: 0..<1000000))
    }
}

// 基于 Noise XX 模式的自动握手 (伪代码)
func initiateSecureHandshake(remotePeer: PeerID) async throws -> SecureSession {
    let noiseConfig = Noise.Config(
        pattern: .XX,
        prologue: "FolderSync-v1".data(using: .utf8)!,
        localKey: Keychain.loadPrivateKey()
    )

    let handshake = try Noise.Handshake(noiseConfig)
    // 1. 发送第一个握手包 (e)
    // 2. 接收响应并处理 (e, ee, s, es)
    // 3. 发送确认包 (s, se)

    let session = try handshake.finalize()
    // 校验 remotePeer.publicKey 是否与握手获取的 s 一致
    guard session.remotePublicKey == remotePeer.publicKey else {
        throw AuthError.peerIdentityMismatch
    }
    return session
}
```

### （5）多文件夹配置模型
```swift
struct SyncFolder: Identifiable, Codable {
    let id: UUID // 本地标识符
    let syncID: String // 全局唯一同步 ID (Link ID)
    var localPath: URL // 本地物理路径
    var mode: SyncMode // .twoWay, .uploadOnly, .downloadOnly
    var status: SyncStatus // .synced, .syncing, .error, .paused
    var syncProgress: Double = 0.0 // 同步进度
    var lastSyncMessage: String? // 最后同步消息
    var lastSyncedAt: Date? // 最后同步时间
    var peerCount: Int = 0 // 参与同步的对等端数量
    var fileCount: Int? = 0 // 文件数量
}

@MainActor
class SyncManager: ObservableObject {
    @Published var folders: [SyncFolder] = []
    @Published var peers: [PeerID] = [] // 已发现的对等端
    var folderPeers: [String: Set<String>] = [:] // SyncID -> PeerIDs 映射

    func addFolder(_ folder: SyncFolder) {
        folders.append(folder)
        try? StorageManager.shared.saveFolder(folder)
        startMonitoring(folder)
        // 启动同步任务
        triggerSync(for: folder)
    }
}
```

# 六、风险与应对

- **性能开销**：大量小文件的 MST 构建可能导致 CPU/IO 压力。*应对：引入异步索引更新机制，分批次写入 SQLite。*
- **网路波动**：广域网高丢包率。*应对：启用 libp2p 的 QUIC 传输，利用其多路复用和拥塞控制。*
- **沙盒权限**：macOS App Sandbox。*应对：使用 Security-Scoped Bookmarks 保持文件夹访问权限。*

# 七、总结

本方案通过引入 **libp2p** 和 **CDC 同步模型**，实现了更稳健、更高效的无服务器文件夹同步。MST 保证了在海量文件下的快速同步一致性，而 Vector Clocks 确保了在多设备并发环境下的一致性逻辑。
