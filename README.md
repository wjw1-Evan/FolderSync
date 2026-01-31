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
    - `stasel/WebRTC` (124.0+): 用于实现 P2P 直接通信和 NAT 穿透。
    - `swift-crypto` (4.0.0+)：用于加密和哈希计算（Ed25519 密钥对、SHA256 哈希等）

## 2. 核心技术模块

- **P2P通信 (WebRTC + TCP Signaling)**：
    - **WebRTC**: 使用 Google WebRTC 协议栈实现 P2P 数据传输。支持 NAT 穿透（STUN/TURN）、端到端加密（DTLS-SRTP）和可靠数据传输（SCTP DataChannels）。
    - **TCP Signaling**: 在局域网内使用轻量级 TCP 服务进行信令交换（SDP Offer/Answer, ICE Candidates），配合 UDP 广播实现自动发现。
- **系统集成 (ServiceManagement)**：利用 `ServiceManagement` 框架（`SMAppService`）实现用户可控的“开机自动启动”功能。
- **文件监控 (FSEvents)**：利用 macOS 原生 FSEvents API 实现高效的目录递归监控，捕获文件创建、修改、删除、重命名等事件。采用防抖机制（2 秒延迟）避免频繁同步。实现文件写入稳定性检测，文件大小稳定 3 秒后才认为写入完成，避免同步不完整的文件。
- **增量同步 (CDC & Merkle Search Trees)**：
    - **内容定义切分 (CDC)**：使用 FastCDC 算法将文件切分为变长数据块，提高数据去重率并解决“插入/删除字节导致偏移失效”的问题。
    - **状态同步 (MST)**：使用 **Merkle Search Trees (MST)** 维护集群状态，通过对比树哈希在 $O(\log n)$ 时间内快速定位差异文件。
- **一致性与冲突处理**：使用 **Vector Clocks** 追踪文件变更的因果关系。同步决策主要基于 Vector Clock 的先后关系（antecedent/successor/equal/concurrent）来决定下载或上传方向。发生并发冲突（concurrent）时，通常会自动保留多版本文件（保存为 `.conflict.{peerID}.{timestamp}` 格式）。**但为了支持文件复活（Resurrection），当本地文件的修改时间明显晚于远程删除记录的删除时间（>1s）时，系统会判定为“复活”操作，优先保留本地新文件并同步给对端。**对于历史上尚未携带 Vector Clock 的旧记录，则采用简单的“本地优先/冲突文件”保守策略，保证最终收敛且不丢数据。
- **设备身份与安全**：
    - **设备身份**：每个设备在首次启动时生成随机 Ed25519 密钥对，PeerID 作为全球唯一标识。
    - **密钥存储**：密钥对存储在本地文件中，使用密码加密保护。密码存储在本地文件中，避免每次启动时要求用户输入系统密码。
    - **对等点管理**：实现智能对等点注册机制（PeerRegistrationService），确保发现的设备能够正确注册并建立连接。支持对等点注册重试和持久化存储。
- **存储机制**：使用 JSON 文件存储文件夹配置、文件索引、Vector Clocks、设备状态、同步日志，避免 SQLite 的 I/O 错误问题。
- **块存储**：实现了块级别的去重存储系统，相同内容的块只存储一次，大幅节省存储空间。块按哈希值组织存储，支持快速查找和访问。
- **文件统计**：实现文件夹统计功能，包括文件数量、文件夹数量和总大小统计。使用流式哈希计算（64KB 缓冲区）避免大文件一次性加载到内存。支持并行处理文件（最大 4 个并发），批量处理（每 50 个文件 yield 一次）避免阻塞主线程。
- **NAT 穿透与中继**：实现了 AutoNAT 检测和 Circuit Relay 中继服务，支持在 NAT 环境下的设备发现和通信，当直连失败时可通过中继服务器进行通信。

# 三、系统架构设计

## 1. 整体架构（分层设计）

采用 **单进程应用架构**，各层通过直接调用和 Swift Concurrency 进行通信：

1. **表现层 (SwiftUI Client)**：提供设备管理、同步文件夹配置、状态实时监控、冲突解决、同步历史等界面。支持菜单栏常驻、单实例运行。主要组件包括：
   - `MainDashboard`：主仪表盘，显示同步状态、速度、设备数量
   - `ConflictCenter`：冲突解决中心，管理冲突文件
   - `SyncHistoryView`：同步历史视图，查看详细同步记录
   - `ExcludeRulesView`：排除规则配置界面
   - `AllPeersListView`：所有设备列表视图

2. **业务逻辑层 (模块化设计)**：采用模块化架构，各模块职责清晰：
   - **SyncManager**：核心同步管理器，负责文件夹管理、同步协调、状态管理。通过 `@MainActor` 和 `ObservableObject` 与 UI 层进行状态同步。
   - **SyncEngine**：同步引擎，负责对等点注册、同步协调和文件同步执行。实现同步冷却期机制（避免频繁同步）、对等点注册重试等。
   - **FileTransfer**：文件传输管理器，负责文件的上传和下载操作。支持全量下载和块级增量同步，自动选择最优传输方式（超过 1MB 的文件使用块级同步）。
   - **FolderStatistics**：文件夹统计管理器，负责文件数量、文件夹数量和总大小的统计计算。使用流式哈希计算避免大文件一次性加载到内存。
   - **FolderMonitor**：文件夹监控管理器，负责文件系统事件监控、文件稳定性检测和同步触发防抖。实现文件写入稳定性检测（文件大小稳定 3 秒后才认为写入完成）。
   - **P2PHandlers**：P2P 消息处理器，负责处理来自对等点的同步请求和响应。

3. **网络层 (WebRTC + LAN Discovery)**：
   - **WebRTCManager**: 封装 `RTCPeerConnection` 和 `RTCDataChannel`，负责 P2P 连接建立和数据传输。
   - **TCPSignalingService**: 负责局域网内的信令交换。
   - **LANDiscovery**: 负责广播 PeerID 和信令地址。
   - **P2PNode**: 协调上述组件，提供统一的 P2P 通信接口。

4. **存储层 (JSON 文件存储)**：使用 JSON 文件存储文件夹配置、文件索引、Vector Clocks、设备状态与同步日志，避免 SQLite 的 I/O 错误问题。

## 2. 核心模块详解

### （1）网络与设备发现 (WebRTC + LAN Discovery)
- **局域网自动发现**：使用 UDP 广播在局域网内自动发现其他设备。设备广播包含 PeerID 和 **TCP 信令端口**。
- **WebRTC 连接**：
  - **信令交换**：通过发现的 TCP 端口建立临时连接，交换 WebRTC 所需的 SDP 和 ICE Candidates。
  - **P2P 数据传输**：建立 WebRTC 连接后，通过 `RTCDataChannel` 进行可靠的数据传输。所有同步请求和文件数据均通过 DataChannel 传输。
  - **NAT 穿透**：WebRTC 内置 ICE 框架，结合 STUN 服务器（默认 Google STUN），具备强大的 NAT 穿透能力。
- **智能对等点注册**：当通过 LAN Discovery 发现对等点时，自动发起 WebRTC 连接流程。
- **安全性**：WebRTC 强制使用 DTLS-SRTP 加密，确保通信内容的机密性和完整性。

### （2）内容定义块管理 (Block Management)
- **FastCDC 算法**：已实现 FastCDC 算法用于文件内容定义切分，支持变长块（4KB-64KB），提高数据去重率并解决"插入/删除字节导致偏移失效"的问题。使用 Gear 哈希算法进行内容定义切分。
- **块级别同步**：已实现块级别的增量同步，支持块级别的去重存储和增量传输。相同内容的块只存储一次，大幅减少网络传输量和存储空间。超过 1MB 的文件自动使用块级增量同步，小于 1MB 的文件使用全量传输。
- **块存储管理**：实现了块存储系统，支持块的保存、获取、存在性检查等操作，按块哈希组织存储结构。支持并行下载缺失的块，提高传输效率。
- **文件级别同步**：同时保留文件级别的同步作为后备方案，当块级同步失败时自动回退到全量下载。

### （3）差分同步 (MST-based Diff)
- **增量列表同步**：相比全量发送文件列表，MST 仅在分支哈希不一致时递归向下探测，极大程度节省元数据交换带宽。

### （4）身份验证与安全
- **设备身份验证**：基于 Ed25519 密钥对的 PeerID 作为设备唯一身份标识，设备间通过 PeerID 进行身份识别。
- **本地存储安全性**：私钥存储在本地文件中，使用密码加密保护。密码存储在本地文件中，避免每次启动时要求用户输入系统密码。
- **端到端加密**：网络层支持 TLS 加密，可通过参数启用。所有数据传输均可选择加密传输，确保数据安全。
- **环境检测**：应用启动时自动检测运行环境（EnvironmentChecker），包括文件系统权限、网络状态等，确保应用正常运行。检测结果会在控制台输出详细报告。

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
### （1）P2P 节点初始化与局域网发现
```swift
class P2PNode {
    // WebRTC 核心组件
    public let webRTC: WebRTCManager
    public let signaling: TCPSignalingService
    
    func start() async throws {
        // ... (PeerID 加载)
        
        // 1. 启动 TCP 信令服务器
        let signalingPort = try signaling.startServer()
        
        // 2. 初始化 WebRTC Manager
        // webRTC 已在 init 中配置了 STUN Server
        
        // 3. 启动 LAN Discovery，广播自己的信令地址
        setupLANDiscovery(peerID: peerID.b58String, signalingPort: signalingPort)
    }
    
    // 处理发现的 Peer
    private func handleDiscoveredPeer(...) {
        // 如果我是发起方 (PeerID 更大)
        if myPeerID > peerID {
            // 创建 WebRTC Offer
            webRTC.createOffer(for: peerID) { sdp in
                // 通过 TCP 信令发送 Offer
                signaling.send(signal: .offer(sdp), to: targetIP)
            }
        }
    }
}
```

### （2）CDC 块切分逻辑
```swift
// FastCDC 算法实现
public class FastCDC {
    private let minSize: Int = 4096  // 4KB
    private let avgSize: Int = 16384 // 16KB
    private let maxSize: Int = 65536 // 64KB
    
    public func chunk(fileURL: URL) throws -> [Chunk] {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        var chunks: [Chunk] = []
        var fingerprint: UInt64 = 0
        var chunkStart = 0
        
        // 使用 Gear 哈希算法进行内容定义切分
        for (index, byte) in data.enumerated() {
            fingerprint = (fingerprint << 1) &+ FastCDC.gearTable[Int(byte)]
            let currentLength = index - chunkStart + 1
            
            // 根据当前长度和指纹决定是否切分
            if currentLength >= minSize {
                let mask = currentLength < avgSize ? 0x3F : 0x1F
                if (fingerprint & mask) == 0 || currentLength >= maxSize {
                    // 切分块
                    let chunkData = data[chunkStart..<index+1]
                    let hash = SHA256.hash(data: chunkData)
                    chunks.append(Chunk(hash: hash, data: chunkData, offset: chunkStart))
                    chunkStart = index + 1
                    fingerprint = 0
                }
            }
        }
        
        return chunks
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
    var fileCount: Int? = nil // 文件数量，nil 表示尚未统计
    var folderCount: Int? = nil // 文件夹数量，nil 表示尚未统计
    var totalSize: Int64? = nil // 全部文件的总大小（字节），nil 表示尚未统计
    var excludePatterns: [String] // 排除规则（.gitignore 风格）
}

@MainActor
class SyncManager: ObservableObject {
    @Published var folders: [SyncFolder] = []
    @Published var uploadSpeedBytesPerSec: Double = 0
    @Published var downloadSpeedBytesPerSec: Double = 0
    @Published var peers: [PeerID] = []
    @Published var onlineDeviceCountValue: Int = 1 // 包括自身
    @Published var offlineDeviceCountValue: Int = 0
    @Published var allDevicesValue: [DeviceInfo] = [] // 设备列表
    
    let p2pNode = P2PNode()
    let syncIDManager = SyncIDManager()
    
    // 模块化组件
    private var folderMonitor: FolderMonitor!
    private var folderStatistics: FolderStatistics!
    private var p2pHandlers: P2PHandlers!
    private var fileTransfer: FileTransfer!
    private var syncEngine: SyncEngine!
    
    // 同步冷却期：避免频繁同步
    var syncCooldown: [String: Date] = [:] // syncID -> 最后同步完成时间
    var syncCooldownDuration: TimeInterval = 5.0 // 同步完成后5秒内忽略文件变化检测
    var peerSyncCooldown: [String: Date] = [:] // "peerID:syncID" -> 最后同步完成时间
    var peerSyncCooldownDuration: TimeInterval = 30.0 // 同步完成后30秒内不重复同步
    
    func addFolder(_ folder: SyncFolder) {
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
            syncEngine.syncWithPeer(peer: peerInfo.peerID, folder: folder)
        }
    }
}
```

# 六、风险与应对

- **性能开销**：大量小文件的 MST 构建可能导致 CPU/IO 压力。*应对：引入异步索引更新机制，使用 JSON 文件存储，避免 SQLite 的 I/O 瓶颈。采用批量处理（每 50 个文件 yield 一次）避免阻塞主线程。*
- **网络波动**：局域网连接可能不稳定。*应对：实现请求重试机制（默认最多 3 次），使用超时控制（文件传输 180 秒，元数据 90 秒），定期检查设备在线状态。*
- **沙盒权限**：macOS App Sandbox。*应对：使用 Security-Scoped Bookmarks 保持文件夹访问权限（未来实现）。当前版本需要用户授予文件夹访问权限。*
- **对等点注册时序**：LAN 发现的对等点可能无法立即注册。*应对：实现智能注册机制（PeerRegistrationService），延迟同步（2.5 秒）确保对等点已完全注册，支持注册重试。*
- **频繁文件变化**：文件监控可能触发大量同步请求。*应对：实现防抖机制（2 秒延迟）、文件写入稳定性检测（文件大小稳定 3 秒后才触发同步）、同步冷却期机制（同步完成后 5 秒内忽略文件变化，对等点-文件夹对 30 秒内不重复同步），避免同步进行中时重复触发。*
- **单实例运行**：防止多个应用实例同时运行导致冲突。*应对：应用启动时检查是否已有实例运行，如有则激活现有实例并退出。*

# 七、当前实现状态

## 已实现功能

### 核心功能
- ✅ 局域网自动发现（UDP 广播，每 5 秒）
- ✅ 原生 TCP 客户端/服务器通信（支持可选的 TLS 加密）
- ✅ 智能对等点注册机制（PeerRegistrationService）
- ✅ 自动设备连接和同步（无需手动配对）
- ✅ 多点同步（同时向多个设备同步）
- ✅ 双向文件同步（支持双向、仅上传、仅下载模式）
- ✅ 块级别增量同步（FastCDC 算法，支持块去重和增量传输）
- ✅ Vector Clock 冲突检测
- ✅ 冲突文件多版本保留（`.conflict.{peerID}.{timestamp}` 格式）
- ✅ 文件删除同步
- ✅ 实时文件监控（FSEvents，带防抖机制）
- ✅ MST 状态对比（快速定位差异文件）
- ✅ 排除规则配置（`.gitignore` 风格）
- ✅ 同步历史记录（详细记录每次同步操作）
- ✅ 本地变更历史记录（记录文件的创建、修改、删除、重命名操作）
- ✅ 基于 Vector Clock 的同步决策（基于因果关系和偏序比较决定同步方向）
- ✅ 冲突解决界面（Conflict Center）
- ✅ 文件/文件夹数量自动统计（包括总大小统计）
- ✅ 文件写入稳定性检测（文件大小稳定 3 秒后才触发同步）
- ✅ 同步冷却期机制（避免频繁同步）
- ✅ 设备在线/离线状态监控（定期检查，每 20 秒）
- ✅ 同步速度统计（上传/下载速度实时显示）
- ✅ NAT 穿透检测（AutoNAT）
- ✅ 中继服务（Circuit Relay，支持广域网同步）

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
- ✅ 块存储管理（块级别去重存储，按哈希组织）
- ✅ TLS 加密支持（网络层支持可选的 TLS 加密）

### UI 功能
- ✅ 主仪表盘（显示同步状态、速度、设备数量、支持下拉刷新）
- ✅ 添加文件夹界面（支持随机生成 syncID）
- ✅ 文件夹列表（显示文件数量、文件夹数量、总大小、同步状态等）
- ✅ 设备列表视图（显示所有设备及在线状态，包括本地设备）
- ✅ 冲突中心（管理冲突文件，支持查看详情和解决冲突）
- ✅ 同步历史视图（查看同步记录，支持筛选和搜索）
- ✅ 排除规则配置界面（支持 `.gitignore` 风格规则）

## 高级功能

### 块级别增量同步 ✅
- **FastCDC 算法**：已实现文件内容定义切分，支持变长块（4KB-64KB），使用 Gear 哈希算法进行内容定义切分，提高数据去重率
- **块存储管理**：实现了块级别的去重存储系统，相同内容的块只存储一次，大幅节省存储空间。块按哈希值组织存储，支持快速查找和访问
- **增量传输**：支持块级别的增量同步，只传输缺失的块，大幅减少网络传输量，特别适合大文件和频繁修改的场景。超过 1MB 的文件自动使用块级增量同步，小于 1MB 的文件使用全量传输
- **并行下载**：支持并行下载缺失的块，提高传输效率
- **协议支持**：扩展了 SyncRequest/SyncResponse 支持块级别请求和响应（`getFileChunks`, `getChunkData`, `putFileChunks`, `putChunkData`）
- **文件重建**：支持从块列表重建完整文件，确保数据完整性
- **自动回退**：当块级同步失败时，自动回退到全量下载，确保同步可靠性

### NAT 穿透与中继 ✅
- **AutoNAT 检测**：自动检测 NAT 类型（公网 IP、对称 NAT、全锥形 NAT 等）和公网可达性
- **Circuit Relay**：实现中继服务，当 NAT 穿透失败或设备无法直连时，可通过中继服务器进行通信
- **中继服务器管理**：支持注册和管理多个中继服务器，自动选择可用的中继服务器
- **广域网支持**：通过中继服务支持跨网络的设备同步，突破局域网限制

### 端到端加密 ✅
- **TLS 支持**：网络层已支持 TLS 加密，可通过 `useTLS` 参数启用
- **可选加密**：支持在 TCP 和 TLS 之间选择，根据安全需求灵活配置
- **证书管理**：当前为简化版本，完整实现需要证书管理机制（未来可扩展为基于 PeerID 的证书体系）

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
   - 自动统计文件/文件夹数量和总大小（使用流式哈希避免大文件内存占用）
   - 实时显示同步速度和设备在线状态
   - 文件式密钥存储，避免每次启动输入系统密码
   - 单实例应用，防止多实例冲突
   - 防抖机制和文件写入稳定性检测，避免频繁同步
   - 同步冷却期机制，避免重复同步
   - 模块化架构，代码结构清晰，易于维护和扩展

5. **同步机制优化**：
   - **基于 Vector Clock 的同步决策**：同步方向主要基于 **Vector Clock** 的偏序关系来决定。系统为每个文件维护 Vector Clock，并基于因果关系进行精确判断。**在此基础上，引入了基于修改时间（mtime）的启发式策略来处理“文件复活”场景：当 Vector Clock 判定为相等或并发，但一方的文件明显更新（通常是重新创建的文件）时，系统会智能识别为“复活”而非冲突，从而自动保留新文件。**对于其他无法自动决断的并发冲突，系统仍会保留多版本文件供用户手动解决。
   - 延迟同步确保对等点已完全注册（2.5 秒延迟）
   - 对等点注册重试机制（最多等待 2 秒，检查间隔 0.2 秒）
   - 请求重试机制（最多 3 次）
   - 超时控制（文件传输 180 秒，元数据 90 秒）
   - 定期设备状态检查（每 20 秒）
   - 同步进度实时更新
   - 块级别增量同步（超过 1MB 的文件自动使用），大幅减少网络传输量
   - 块去重存储，节省存储空间
   - 文件写入稳定性检测，避免同步不完整的文件
   - 同步冷却期机制（文件夹级别 5 秒，对等点-文件夹对 30 秒）
   - 最大并发传输数控制（3 个并发传输）

6. **冲突处理**：使用 Vector Clocks 检测并发修改。**对于“本地文件存在 vs 远程文件已删除”的冲突场景，系统会结合修改时间（mtime）智能判断是否为“文件复活”，避免误删刚恢复的文件。**对于真正的并发修改冲突，系统会自动保留冲突文件的多版本，由用户在冲突中心手动解决，确保数据不丢失。

## 技术架构优势

- **无服务器架构**：完全 P2P 通信，无需中央服务器
- **局域网优化**：针对局域网环境优化，自动发现和连接
- **广域网支持**：通过 NAT 穿透和中继服务支持跨网络同步
- **原生实现**：使用 macOS 原生 API，减少依赖，提高稳定性
- **异步处理**：充分利用 Swift Concurrency，提高性能和响应速度
- **状态管理**：使用 ObservableObject 和 @Published 实现响应式 UI 更新
- **高效同步**：块级别增量同步和去重，大幅提升同步效率和存储利用率
- **安全传输**：支持 TLS 加密，确保数据传输安全

# 九、与 OneDrive 等云同步服务的对比

## 同步机制对比

| 特性 | OneDrive | FolderSync |
|------|----------|------------|
| **架构模式** | 中央服务器（客户端-服务器） | P2P（点对点，无服务器） |
| **数据存储** | 云端服务器存储 | 本地存储，设备间直连 |
| **块级同步** | ✅ 固定块大小（4MB） | ✅ 变长块（FastCDC，4KB-64KB） |
| **增量传输** | ✅ 只传输变更块 | ✅ 只传输缺失块 |
| **冲突处理** | 时间戳 + 版本号 | Vector Clocks + 智能复活检测 |
| **元数据同步** | MST 类似机制 | MST（Merkle Search Trees） |
| **文件监控** | 实时监控 | FSEvents 实时监控 |
| **同步决策** | 基于文件修改时间（mtime） | 基于 Vector Clock 的因果关系 |
| **去重存储** | ✅ 服务器端去重 | ✅ 本地块级去重 |
| **版本历史** | ✅ 云端版本历史 | ❌ 无版本历史（未来可扩展） |
| **协作功能** | ✅ 多人协作编辑 | ❌ 不支持（P2P 架构限制） |
| **跨平台** | ✅ Windows/macOS/iOS/Android | ✅ macOS（当前） |
| **离线访问** | ❌ 需要网络连接 | ✅ 完全离线工作 |
| **隐私保护** | ⚠️ 数据存储在第三方服务器 | ✅ 数据完全本地，不经过第三方 |
| **成本** | 💰 需要订阅费用 | ✅ 完全免费 |
| **速度** | ⚠️ 受网络带宽限制 | ✅ 局域网内高速直连 |
| **控制权** | ⚠️ 受服务商限制 | ✅ 完全自主控制 |

## 技术实现对比

### OneDrive 同步机制

1. **文件监控**：实时监控文件系统变化
2. **块级同步**：将文件切分为固定大小的块（4MB），只传输变更的块
3. **元数据同步**：先同步文件列表和元数据，快速识别需要同步的文件
4. **冲突处理**：基于时间戳和版本号，冲突时保留两个版本
5. **防抖机制**：文件写入完成后才触发同步

### FolderSync 同步机制

1. **文件监控**：使用 FSEvents 实时监控文件系统变化，带防抖机制（2秒延迟）
2. **块级同步**：使用 FastCDC 算法将文件切分为变长块（4KB-64KB），提高去重率
3. **元数据同步**：使用 MST（Merkle Search Trees）快速定位差异文件
4. **冲突处理**：使用 Vector Clocks 追踪因果关系并决定同步方向，对并发修改生成多版本冲突文件；**针对文件复活场景引入智能检测机制**
5. **防抖机制**：文件大小稳定 3 秒后才触发同步，避免同步不完整文件

## 优势对比

### OneDrive 的优势

1. **云端存储**：文件存储在云端，可随时访问，不受设备限制
2. **版本历史**：保留文件历史版本，可恢复误删或误改的文件
3. **协作功能**：支持多人同时编辑文档，实时协作
4. **跨平台**：支持多个平台，统一体验
5. **可靠性**：服务器端备份，数据安全性高

### FolderSync 的优势

1. **隐私保护**：数据完全本地存储，不经过任何第三方服务器
2. **高速同步**：局域网内设备直连，同步速度快
3. **零成本**：无需订阅费用，完全免费
4. **完全控制**：用户完全控制同步逻辑和数据流向
5. **离线工作**：完全离线工作，不依赖互联网连接
6. **灵活配置**：支持自定义排除规则和同步模式
7. **智能同步**：基于 Vector Clock 的因果关系判断，确保同步决策的准确性和一致性

## 适用场景

### OneDrive 适合：

- 需要云端备份和跨设备访问
- 需要多人协作编辑文档
- 需要文件版本历史功能
- 需要跨平台统一体验
- 对隐私要求不高的场景

### FolderSync 适合：

- 注重隐私和数据安全
- 局域网内多设备同步
- 需要完全控制数据流向
- 不想支付云存储费用
- 需要高速同步（局域网环境）
- macOS 平台专用场景
