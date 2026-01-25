# macOS无服务器文件夹自动同步客户端设计方案（Swift）

# 一、项目概述

## 核心功能

**客户端之间文件自动同步**：实现多台 macOS 设备之间的文件夹自动同步，无需中央服务器。当一台设备上的文件发生变化时，其他设备会自动检测并同步更新，确保所有设备上的文件保持一致。

## 项目描述

本项目是一款基于 macOS 平台的客户端程序，采用 Swift 语言编写，通过 P2P（点对点）技术实现多台电脑之间文件夹的自动同步，全程无需依赖中央服务器。程序具备设备自动发现、实时文件监控、基于内容块的增量同步、端到端加密等核心功能，兼顾同步效率、数据安全与用户体验，适用于家庭、小型团队等场景下的多设备文件协同管理。

> 运行提示：局域网自动发现已启用（基于 UDP 广播）。请确保各客户端均连接同一子网以进行自动发现。如果自动发现失败，用户仍可通过分享 PeerID 手动连接设备。

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

- **P2P通信 (原生 TCP)**：使用 macOS 原生 Network 框架实现 TCP 客户端/服务器通信，通过 UDP 广播实现局域网自动发现。设备间通过原生 TCP 连接直接通信，无需依赖第三方 P2P 框架。
- **系统集成 (ServiceManagement)**：利用 `ServiceManagement` 框架（`SMAppService`）实现用户可控的“开机自动启动”功能。
- **文件监控 (FSEvents)**：利用 macOS 原生 FSEvents API 实现高效的目录递归监控，捕获文件创建、修改、删除、重命名等事件。采用防抖机制（2 秒延迟）避免频繁同步。
- **增量同步 (CDC & Merkle Search Trees)**：
    - **内容定义切分 (CDC)**：使用 FastCDC 算法将文件切分为变长数据块，提高数据去重率并解决“插入/删除字节导致偏移失效”的问题。
    - **状态同步 (MST)**：使用 **Merkle Search Trees (MST)** 维护集群状态，通过对比树哈希在 $O(\log n)$ 时间内快速定位差异文件。
- **一致性与冲突处理**：使用 **Vector Clocks** 追踪文件变更的因果关系。冲突发生时，自动保留多版本文件（保存为 `.conflict.{peerID}.{timestamp}` 格式），用户可通过冲突中心手动解决。
- **设备身份与安全**：
    - **设备身份**：每个设备在首次启动时生成随机 Ed25519 密钥对，PeerID 作为全球唯一标识。
    - **密钥存储**：密钥对存储在本地文件中，使用密码加密保护。密码存储在本地文件中，避免每次启动时要求用户输入系统密码。
    - **对等点管理**：实现智能对等点注册机制，确保发现的设备能够正确注册并建立连接。
- **存储机制**：使用 JSON 文件存储文件夹配置、文件索引、Vector Clocks、设备状态与同步日志，避免 SQLite 的 I/O 错误问题。

# 三、系统架构设计

## 1. 整体架构（分层设计）

采用 **单进程应用架构**，各层通过直接调用和 Swift Concurrency 进行通信：

1. **表现层 (SwiftUI Client)**：提供设备管理、同步文件夹配置、状态实时监控、冲突解决、同步历史等界面。支持菜单栏常驻、单实例运行。
2. **业务逻辑层 (Sync Engine)**：负责文件索引管理、因果追踪、冲突策略执行、同步任务调度、设备状态监控。通过 `@MainActor` 和 `ObservableObject` 与 UI 层进行状态同步。实现多点同步（同时向多个设备同步）、防抖机制、文件/文件夹数量统计等功能。
3. **网络层 (原生 TCP + LAN Discovery)**：使用原生 TCP 客户端/服务器实现设备间通信，通过 UDP 广播实现局域网自动发现。包括对等点发现、连接管理、地址转换、对等点注册服务等。通过异步回调与业务逻辑层通信。
4. **存储层 (JSON 文件存储)**：使用 JSON 文件存储文件夹配置、文件索引、Vector Clocks、设备状态与同步日志，避免 SQLite 的 I/O 错误问题。

## 2. 核心模块详解

### （1）网络与设备发现 (原生 TCP + LAN Discovery)
- **局域网自动发现**：使用 UDP 广播在局域网内自动发现其他设备，无需手动配置。设备每 5 秒广播一次自己的 PeerID 和监听地址，并监听其他设备的广播消息。这是主要的设备发现机制，完全在局域网内工作，无需任何服务器。
- **原生 TCP 通信**：使用 macOS 原生 Network 框架实现 TCP 客户端/服务器，设备间通过 TCP 连接直接通信。服务器自动分配端口，客户端通过地址转换从多地址格式中提取 IP:Port 进行连接。
- **智能对等点注册**：当通过 LAN Discovery 发现对等点时，系统会自动将对等点注册到 PeerManager 和 PeerRegistrationService 中，确保后续的连接能够成功建立。注册过程包括：
  - 解析对等点的 PeerID 和监听地址
  - 将对等点添加到 PeerManager 的持久化存储
  - 通过 PeerRegistrationService 管理注册状态
  - 延迟同步以确保对等点已完全注册
- **自动连接与多点同步**：发现设备后自动建立连接并开始同步，无需任何手动配对步骤。支持同时向多个已注册的设备进行同步（多点同步）。所有通信均在客户端之间直接进行（P2P），无需中央服务器。
- **设备状态监控**：定期检查设备在线状态（每 20 秒），自动更新设备在线/离线状态，并在 UI 中实时显示。
- **纯 P2P 架构**：客户端之间通过原生 TCP 协议直接通信，所有数据传输都在设备间直连完成，不经过任何中间服务器。
- **对等点身份**：基于 Ed25519 密钥对生成 PeerID，作为设备唯一身份标识。密钥对存储在本地文件中，使用密码加密保护。
- **地址管理**：实现地址转换器（AddressConverter）处理多地址格式，从 libp2p 多地址格式中提取可用的 IP:Port 地址用于 TCP 连接。

### （2）内容定义块管理 (Block Management)
- **FastCDC 算法**：已实现 FastCDC 算法用于文件内容定义切分，为未来的块级别同步优化做准备。
- **当前实现**：当前版本采用文件级别的同步，通过文件哈希对比快速识别需要同步的文件。
- **未来优化**：计划实现块级别的去重存储和增量传输，进一步提升大文件同步效率。

### （3）差分同步 (MST-based Diff)
- **增量列表同步**：相比全量发送文件列表，MST 仅在分支哈希不一致时递归向下探测，极大程度节省元数据交换带宽。

### （4）身份验证与安全
- **设备身份验证**：基于 Ed25519 密钥对的 PeerID 作为设备唯一身份标识，设备间通过 PeerID 进行身份识别。
- **本地存储安全性**：私钥存储在本地文件中，使用密码加密保护。密码存储在本地文件中，避免每次启动时要求用户输入系统密码。
- **环境检测**：应用启动时自动检测运行环境，包括文件系统权限、网络状态等，确保应用正常运行。

# 四、GUI 界面设计

1. **仪表盘 (Dashboard)**：显示整体同步进度、实时上传/下载速度、连接对等点数量。
2. **文件夹管理中心**：
    - **多文件夹支持**：列表化管理多个同步文件夹。用户可为每个文件夹分配唯一的“同步 ID”，用于跨设备关联。
    - **选择性同步**：支持配置独立的排除规则（`.gitignore` 风格）及同步模式（双向/单向）。
3. **对等点视图**：展示已知设备列表，标记连接路径（直连/Relay）及同步偏移量。
4. **版本/冲突中心**：展示变更历史及需要手动介入的冲突文件。
5. **菜单栏常驻 (Menu Bar Extra)**：
    - 快速打开主窗口、退出程序。
    - 开启/关闭"开机自动启动"功能。

# 五、代码实现方案 (核心逻辑)

### （1）P2P 节点初始化与局域网发现
```swift
class P2PNode {
    private var lanDiscovery: LANDiscovery?
    public let peerManager: PeerManager
    public let registrationService: PeerRegistrationService
    public let nativeNetwork: NativeNetworkService
    
    func start() async throws {
        // 加载或生成密钥对
        let keyPair = try loadOrGenerateKeyPair()
        myPeerID = keyPair.peerID
        
        // 启动原生 TCP 服务器
        let port = try nativeNetwork.startServer(port: 0)
        
        // 启用 UDP 广播局域网发现
        let discovery = LANDiscovery()
        discovery.onPeerDiscovered = { [weak self] peerID, address, peerAddresses in
            await self?.connectToDiscoveredPeer(peerID: peerID, addresses: peerAddresses)
        }
        discovery.start(peerID: myPeerID.b58String, listenAddresses: ["/ip4/0.0.0.0/tcp/\(port)"])
        
        // 设置对等点发现回调
        self.onPeerDiscovered = { peer in
            // 触发同步管理器开始同步
        }
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

### （3）系统集成：单实例、菜单栏与开机启动
```swift
@main
struct FolderSyncApp: App {
    @StateObject private var syncManager = SyncManager()
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    
    init() {
        // 单实例检查
        let bundleID = Bundle.main.bundleIdentifier ?? "com.FolderSync.App"
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let currentApp = NSRunningApplication.current
        
        for app in runningApps {
            if app != currentApp {
                app.activate()
                exit(0) // 退出当前实例
            }
        }
        
        // 同步系统登录项状态到 UI
        syncLaunchAtLoginStatus()
    }
    
    var body: some Scene {
        WindowGroup(id: "main") {
            MainDashboard()
                .environmentObject(syncManager)
        }
        .commands {
            CommandGroup(replacing: .newItem) {} // 移除"新建窗口"菜单项
        }
        
        MenuBarExtra("FolderSync", systemImage: "arrow.triangle.2.circlepath") {
            Button("显示主界面") {
                // 检查窗口是否已存在，存在则激活，否则打开新窗口
                let existingWindow = NSApplication.shared.windows.first { window in
                    window.isVisible && window.identifier?.rawValue == "main"
                }
                if let window = existingWindow {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(id: "main")
                }
            }
            Divider()
            Toggle("开机自动启动", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { oldValue, newValue in
                    toggleLaunchAtLogin(newValue)
                }
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
    
    // 开机启动控制 (macOS 13+)
    private func toggleLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            // 操作后同步状态，确保 UI 与系统状态一致
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.syncLaunchAtLoginStatus()
            }
        } catch {
            print("设置开机启动失败: \(error)")
            syncLaunchAtLoginStatus() // 失败时恢复 UI 状态
        }
    }
}
```

### （4）局域网发现实现
```swift
// UDP 广播局域网发现
class LANDiscovery {
    private let servicePort: UInt16 = 8765
    
    func start(peerID: String) {
        // 启动 UDP 监听
        let listener = try NWListener(using: .udp, on: servicePort)
        listener.newConnectionHandler = { connection in
            // 接收其他设备的广播消息
        }
        
        // 定期广播本机 PeerID
        Timer.scheduledTimer { _ in
            self.sendBroadcast(peerID: peerID)
        }
    }
    
    private func sendBroadcast(peerID: String) {
        // 向 255.255.255.255 广播 PeerID
        let message = createDiscoveryMessage(peerID: peerID)
        // 发送 UDP 广播
    }
}
```

### （5）多文件夹配置模型与同步管理
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
    var folderCount: Int? = 0 // 文件夹数量
    var excludePatterns: [String] // 排除规则（.gitignore 风格）
}

@MainActor
class SyncManager: ObservableObject {
    @Published var folders: [SyncFolder] = []
    @Published var uploadSpeedBytesPerSec: Double = 0
    @Published var downloadSpeedBytesPerSec: Double = 0
    @Published var peers: [PeerID] = []
    @Published var onlineDeviceCount: Int = 1 // 包括自身
    @Published var offlineDeviceCount: Int = 0
    
    let p2pNode = P2PNode()
    let syncIDManager = SyncIDManager()
    
    // 文件监控防抖：syncID -> 防抖任务
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private let debounceDelay: TimeInterval = 2.0 // 2 秒防抖延迟
    
    func addFolder(_ folder: SyncFolder) {
        // 验证文件夹权限和 syncID 格式
        // 注册 syncID 到管理器
        syncIDManager.registerSyncID(folder.syncID, folderID: folder.id)
        
        folders.append(folder)
        try? StorageManager.shared.saveFolder(folder)
        startMonitoring(folder)
        
        // 立即统计文件数量和文件夹数量
        refreshFileCount(for: folder)
        
        // 延迟同步，确保对等点已注册
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self.triggerSync(for: folder)
        }
    }
    
    // 多点同步：同时向所有已注册的对等点同步
    func triggerSync(for folder: SyncFolder) {
        let registeredPeers = peerManager.allPeers.filter { peerInfo in
            p2pNode.registrationService.isRegistered(peerInfo.peerIDString)
        }
        
        for peerInfo in registeredPeers {
            syncWithPeer(peer: peerInfo.peerID, folder: folder)
        }
    }
}
```

# 六、风险与应对

- **性能开销**：大量小文件的 MST 构建可能导致 CPU/IO 压力。*应对：引入异步索引更新机制，使用 JSON 文件存储，避免 SQLite 的 I/O 瓶颈。采用批量处理（每 50 个文件 yield 一次）避免阻塞主线程。*
- **网络波动**：局域网连接可能不稳定。*应对：实现请求重试机制（默认最多 3 次），使用超时控制（文件传输 180 秒，元数据 90 秒），定期检查设备在线状态。*
- **沙盒权限**：macOS App Sandbox。*应对：使用 Security-Scoped Bookmarks 保持文件夹访问权限（未来实现）。当前版本需要用户授予文件夹访问权限。*
- **对等点注册时序**：LAN 发现的对等点可能无法立即注册。*应对：实现智能注册机制（PeerRegistrationService），延迟同步（2.5 秒）确保对等点已完全注册，支持注册重试。*
- **频繁文件变化**：文件监控可能触发大量同步请求。*应对：实现防抖机制（2 秒延迟），避免同步进行中时重复触发。*
- **单实例运行**：防止多个应用实例同时运行导致冲突。*应对：应用启动时检查是否已有实例运行，如有则激活现有实例并退出。*

# 七、当前实现状态

## 已实现功能

### 核心功能
- ✅ 局域网自动发现（UDP 广播，每 5 秒）
- ✅ 原生 TCP 客户端/服务器通信
- ✅ 智能对等点注册机制（PeerRegistrationService）
- ✅ 自动设备连接和同步（无需手动配对）
- ✅ 多点同步（同时向多个设备同步）
- ✅ 双向文件同步（支持双向、仅上传、仅下载模式）
- ✅ Vector Clock 冲突检测
- ✅ 冲突文件多版本保留（`.conflict.{peerID}.{timestamp}` 格式）
- ✅ 文件删除同步
- ✅ 实时文件监控（FSEvents，带防抖机制）
- ✅ MST 状态对比（快速定位差异文件）
- ✅ 排除规则配置（`.gitignore` 风格）
- ✅ 同步历史记录（详细记录每次同步操作）
- ✅ 冲突解决界面（Conflict Center）
- ✅ 文件/文件夹数量自动统计
- ✅ 设备在线/离线状态监控（定期检查，每 20 秒）
- ✅ 同步速度统计（上传/下载速度实时显示）

### 系统集成
- ✅ 单实例应用（防止多实例运行）
- ✅ 菜单栏常驻应用
- ✅ 开机自动启动（ServiceManagement，自动同步系统状态）
- ✅ 环境检测（启动时检测运行环境）

### 存储与安全
- ✅ JSON 文件存储（替代 SQLite，避免 I/O 错误）
- ✅ 文件式密钥存储（避免每次启动输入系统密码）
- ✅ Ed25519 密钥对生成和管理
- ✅ PeerID 持久化存储

### UI 功能
- ✅ 主仪表盘（显示同步状态、速度、设备数量）
- ✅ 添加文件夹界面（支持随机生成 syncID）
- ✅ 设备列表视图（显示所有设备及在线状态）
- ✅ 冲突中心（管理冲突文件）
- ✅ 同步历史视图（查看同步记录）
- ✅ 排除规则配置界面

## 开发中功能
- 🚧 块级别增量同步（FastCDC 算法已实现，待集成到同步流程）
- 🚧 NAT 穿透（AutoNAT 和 Circuit Relay，用于广域网同步）
- 🚧 端到端加密（当前使用原生 TCP，未来可添加 TLS/Noise 协议）

# 八、总结

本方案通过使用**原生 TCP 通信**和**CDC 同步模型**，实现了更稳健、更高效的无服务器文件夹同步。使用 UDP 广播实现局域网自动发现，设备无需手动配置即可自动连接和同步。实现了智能对等点注册机制，确保通过 LAN Discovery 发现的对等点能够正确注册并建立连接。MST 保证了在海量文件下的快速同步一致性，而 Vector Clocks 确保了在多设备并发环境下的一致性逻辑。

## 关键技术特点

1. **原生网络实现**：使用 macOS 原生 Network 框架实现 TCP 客户端/服务器，避免了第三方 P2P 框架的复杂性，提高了稳定性和可控性。

2. **智能对等点管理**：
   - 实现 PeerManager 统一管理对等点信息（包括地址、在线状态、发现时间等）
   - 实现 PeerRegistrationService 管理对等点注册状态
   - 支持对等点持久化存储，重启后自动恢复
   - 延迟同步机制确保对等点已完全注册后再开始同步

3. **存储优化**：从 SQLite 迁移到 JSON 文件存储，避免了 SQLite 的 I/O 错误问题，提高了存储的可靠性。支持文件夹配置、Vector Clocks、同步日志、冲突文件等数据的持久化。

4. **用户体验优化**：
   - 完全自动的设备发现和连接，无需手动配对
   - 支持多点同步，同时向多个设备同步
   - 自动统计文件/文件夹数量
   - 实时显示同步速度和设备在线状态
   - 文件式密钥存储，避免每次启动输入系统密码
   - 单实例应用，防止多实例冲突
   - 防抖机制，避免频繁同步

5. **同步机制优化**：
   - 延迟同步确保对等点已完全注册
   - 请求重试机制（最多 3-5 次）
   - 超时控制（文件传输 180 秒，元数据 90 秒）
   - 定期设备状态检查（每 20 秒）
   - 同步进度实时更新

6. **冲突处理**：使用 Vector Clocks 检测并发修改，自动保留冲突文件的多版本，用户可通过冲突中心手动解决。

## 技术架构优势

- **无服务器架构**：完全 P2P 通信，无需中央服务器
- **局域网优化**：针对局域网环境优化，自动发现和连接
- **原生实现**：使用 macOS 原生 API，减少依赖，提高稳定性
- **异步处理**：充分利用 Swift Concurrency，提高性能和响应速度
- **状态管理**：使用 ObservableObject 和 @Published 实现响应式 UI 更新
