import SwiftUI
import Combine
import Crypto

@MainActor
public class SyncManager: ObservableObject {
    @Published var folders: [SyncFolder] = []
    @Published var uploadSpeedBytesPerSec: Double = 0
    @Published var downloadSpeedBytesPerSec: Double = 0
    let p2pNode = P2PNode()
    
    // 使用统一的 Peer 管理器
    public var peerManager: PeerManager {
        return p2pNode.peerManager
    }
    
    // 使用统一的 SyncID 管理器
    public let syncIDManager = SyncIDManager()
    
    // 兼容性：提供 peers 属性（从 peerManager 获取）
    @Published var peers: [PeerID] = []
    
    // 速度统计
    private var uploadSamples: [(Date, Int64)] = []
    private var downloadSamples: [(Date, Int64)] = []
    private let speedWindow: TimeInterval = 3
    
    // 同步状态管理
    var lastKnownLocalPaths: [String: Set<String>] = [:]
    var lastKnownMetadata: [String: [String: FileMetadata]] = [:] // syncID -> [path: metadata] 用于重命名检测
    var deletedPaths: [String: Set<String>] = [:]
    var syncInProgress: Set<String> = [] // 正在同步的 (syncID, peerID) 组合，格式: "syncID:peerID"
    private var peerStatusCheckTask: Task<Void, Never>?
    private var peersSyncTask: Task<Void, Never>? // 定期同步 peers 数组的任务
    private var peerDiscoveryTask: Task<Void, Never>? // 对等点发现处理任务
    
    // 同步完成后的冷却时间：记录每个 syncID 的最后同步完成时间，在冷却期内忽略文件变化检测
    var syncCooldown: [String: Date] = [:] // syncID -> 最后同步完成时间
    var syncCooldownDuration: TimeInterval = 5.0 // 同步完成后5秒内忽略文件变化检测
    
    // 按 peer-folder 对记录的同步冷却时间，用于避免频繁同步
    var peerSyncCooldown: [String: Date] = [:] // "peerID:syncID" -> 最后同步完成时间
    var peerSyncCooldownDuration: TimeInterval = 30.0 // 同步完成后30秒内不重复同步
    
    // 设备统计（用于触发UI更新）
    @Published private(set) var onlineDeviceCountValue: Int = 1 // 包括自身，默认为1
    @Published private(set) var offlineDeviceCountValue: Int = 0
    @Published private(set) var allDevicesValue: [DeviceInfo] = [] // 设备列表（用于触发UI更新）
    
    // 模块化组件
    private var folderMonitor: FolderMonitor!
    private var folderStatistics: FolderStatistics!
    private var p2pHandlers: P2PHandlers!
    private var fileTransfer: FileTransfer!
    private var syncEngine: SyncEngine!
    
    public init() {
        // 运行环境检测
        print("\n[EnvironmentCheck] 开始环境检测...")
        let reports = EnvironmentChecker.runAllChecks()
        EnvironmentChecker.printReport(reports)
        
        // Load from storage
        do {
            let loadedFolders = try StorageManager.shared.getAllFolders()
            self.folders = loadedFolders
            if !loadedFolders.isEmpty {
                for folder in loadedFolders {
                    // 注册 syncID 到管理器
                    let registered = syncIDManager.registerSyncID(folder.syncID, folderID: folder.id)
                    if !registered {
                        print("[SyncManager] ⚠️ 警告: syncID 注册失败（可能已存在）: \(folder.syncID)")
                    }
                    print("[SyncManager]   - 文件夹: \(folder.localPath.path) (syncID: \(folder.syncID))")
                }
            }
        } catch {
            print("[SyncManager] ❌ 加载文件夹配置失败: \(error)")
            print("[SyncManager] 错误详情: \(error.localizedDescription)")
            self.folders = []
        }
        
        // 初始化设备统计（自身始终在线）
        updateDeviceCounts() // 这会同时更新 allDevicesValue
        
        // 初始化模块化组件
        folderMonitor = FolderMonitor(syncManager: self)
        folderStatistics = FolderStatistics(syncManager: self, folderMonitor: folderMonitor)
        p2pHandlers = P2PHandlers(syncManager: self, folderStatistics: folderStatistics)
        fileTransfer = FileTransfer(syncManager: self)
        syncEngine = SyncEngine(syncManager: self, fileTransfer: fileTransfer, folderStatistics: folderStatistics)
        
        // 监听 peerManager 的变化，同步更新 peers 数组和设备列表（用于兼容性和自动刷新）
        peersSyncTask = Task { @MainActor in
            // 定期同步 peers 数组和设备列表
            while !Task.isCancelled {
                let allPeers = peerManager.allPeers.map { $0.peerID }
                if self.peers != allPeers {
                    self.peers = allPeers
                }
                
                // 同时更新设备列表，确保 UI 自动刷新
                self.updateAllDevices()
                
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 每秒同步一次
            }
        }
        
        peerDiscoveryTask = Task { @MainActor in
            p2pNode.onPeerDiscovered = { [weak self] peer in
                Task { @MainActor in
                    guard let self = self else { return }
                    let peerIDString = peer.b58String
                    guard !peerIDString.isEmpty else { return }
                    
                    let wasNew = !self.peerManager.hasPeer(peerIDString)
                    // 不要覆盖已有的地址
                    // P2PNode.connectToDiscoveredPeer 已经添加了地址到 PeerManager
                    // 如果 peer 不存在，则添加（地址会在 connectToDiscoveredPeer 中添加）
                    // 如果 peer 已存在，则保留其现有地址，只更新在线状态
                    if wasNew {
                        // 新 peer，先添加（地址会在 connectToDiscoveredPeer 中添加）
                        // 这里使用空数组，因为地址会在 connectToDiscoveredPeer 中通过 addOrUpdatePeer 添加
                        self.peerManager.addOrUpdatePeer(peer, addresses: [])
                    }
                    // 更新在线状态（无论新旧 peer 都需要更新）
                    // 收到广播表示设备在线，更新 lastSeenTime 和在线状态
                    let wasOnline = self.peerManager.isOnline(peerIDString)
                    self.peerManager.updateOnlineStatus(peerIDString, isOnline: true)
                    self.peerManager.updateLastSeen(peerIDString) // 更新最后可见时间
                    
                    // 验证 lastSeenTime 是否已更新
                    if let peerInfo = self.peerManager.getPeer(peerIDString) {
                        let timeSinceUpdate = Date().timeIntervalSince(peerInfo.lastSeenTime)
                        if timeSinceUpdate > 1.0 {
                            print("[SyncManager] ⚠️ 警告: lastSeenTime 更新后时间差异常: \(timeSinceUpdate)秒")
                        }
                    }
                    
                    // 收到广播时，无论状态是否变化，都更新设备统计和列表，确保同步
                    // 这样可以确保统计数据和"所有设备"列表始终保持一致
                    self.updateDeviceCounts()
                    if wasNew || !wasOnline {
                    }
                    // 减少收到广播的日志输出，只在状态变化时输出
                    
                    // 对于新对等点，立即触发同步
                    // 对于已存在的对等点，只有在最近没有同步过的情况下才触发同步
                    // 避免频繁触发不必要的同步
                    Task { @MainActor in
                        // syncWithPeer 内部会处理对等点注册，这里直接调用即可
                        if wasNew {
                            // 向所有文件夹同步（多点同步）
                            for folder in self.folders {
                                self.syncWithPeer(peer: peer, folder: folder)
                            }
                        } else {
                            // 只同步不在冷却期内的文件夹
                            for folder in self.folders {
                                if self.shouldSyncFolderWithPeer(peerID: peerIDString, folder: folder) {
                                    self.syncWithPeer(peer: peer, folder: folder)
                                }
                            }
                        }
                    }
                }
            }
            
            // 启动 P2P 节点，如果失败则记录详细错误
            do {
                try await p2pNode.start()
            } catch {
                print("[SyncManager] ❌ P2P 节点启动失败: \(error)")
                print("[SyncManager] 错误详情: \(error.localizedDescription)")
                if let nsError = error as NSError? {
                    print("[SyncManager] 错误域: \(nsError.domain), 错误码: \(nsError.code)")
                    print("[SyncManager] 用户信息: \(nsError.userInfo)")
                }
                // 继续执行，但 P2P 功能将不可用
                await MainActor.run {
                    for folder in self.folders {
                        self.updateFolderStatus(folder.id, status: .error, message: "P2P 节点启动失败: \(error.localizedDescription)")
                    }
                }
            }
            
            // Register P2P handlers
            p2pHandlers.setupP2PHandlers()
            
            // Start monitoring and announcing all folders
            await MainActor.run {
                for folder in folders {
                    startMonitoring(folder)
                    // 启动后自动统计文件数量（使用最新的 folder 对象）
                    if let latestFolder = folders.first(where: { $0.id == folder.id }) {
                        refreshFileCount(for: latestFolder)
                    }
                }
            }
            
            // 启动定期检查设备在线状态
            startPeerStatusMonitoring()
            
            // 启动后等待一段时间，然后对所有已注册的在线对等点触发同步
            // 这确保后启动的客户端能够自动同步文件
            Task { @MainActor in
                // 等待5秒，确保所有对等点都已发现并注册
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                
                // 获取所有已注册的在线对等点
                let registeredPeers = peerManager.allPeers.filter { peerInfo in
                    p2pNode.registrationService.isRegistered(peerInfo.peerIDString) &&
                    peerManager.isOnline(peerInfo.peerIDString)
                }
                
                if !registeredPeers.isEmpty {
                    // 对所有已注册的在线对等点触发同步
                    for folder in folders {
                        for peerInfo in registeredPeers {
                            syncWithPeer(peer: peerInfo.peerID, folder: folder)
                        }
                    }
                }
            }
        }
    }
    
    /// 启动定期检查设备在线状态
    private func startPeerStatusMonitoring() {
        peerStatusCheckTask?.cancel()
        peerStatusCheckTask = Task { [weak self] in
            // 首次等待 30 秒，给设备足够时间完成连接和注册
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            
            while !Task.isCancelled {
                guard let self = self else { break }
                await self.checkAllPeersOnlineStatus()
                // 每 10 秒检查一次，更快检测离线设备
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }
    
    deinit {
        peerStatusCheckTask?.cancel()
        peersSyncTask?.cancel()
        peerDiscoveryTask?.cancel()
        // 取消所有监控任务
        Task { @MainActor [folderMonitor] in
            folderMonitor?.cancelAll()
        }
    }
    
    /// 检查所有对等点的在线状态
    private func checkAllPeersOnlineStatus() async {
        // 注意：SyncManager 是 @MainActor，所以可以直接访问 peerManager
        let peersToCheck = peerManager.allPeers
        guard !peersToCheck.isEmpty else {
            // 如果没有对等点，重置设备计数（只保留自身）
            onlineDeviceCountValue = 1
            offlineDeviceCountValue = 0
            // 同时更新所有文件夹的 peerCount
            for folder in folders {
                updatePeerCount(for: folder.syncID)
            }
            return
        }
        
        var statusChanged = false
        
        for peerInfo in peersToCheck {
            let peerIDString = peerInfo.peerIDString
            // 使用 deviceStatuses 作为权威状态源
            let wasOnline = peerManager.isOnline(peerIDString)
            
            // 重新获取最新的 peerInfo（可能在检查过程中收到了新广播）
            let currentPeerInfo = peerManager.getPeer(peerIDString)
            guard let currentPeer = currentPeerInfo else {
                print("[SyncManager] ⚠️ Peer 不存在，跳过检查: \(peerIDString.prefix(12))...")
                continue
            }
            
            // 先检查最近是否收到过广播（30秒内）
            // 如果最近收到过广播，直接认为在线，不需要发送请求检查
            // 注意：广播间隔是1秒，检查间隔是10秒，考虑到UDP可能丢包，设置30秒窗口
            // 这样即使连续丢失2-3个广播包，只要在30秒内收到一次，就认为在线
            let recentlySeen: Bool = {
                let timeSinceLastSeen = Date().timeIntervalSince(currentPeer.lastSeenTime)
                return timeSinceLastSeen < 30.0 // 30秒窗口，平衡响应速度和容错性
            }()
            
            let isOnline: Bool
            if recentlySeen {
                // 最近收到过广播，认为在线
                isOnline = true
            } else {
                // 没有最近收到广播，如果设备已经标记为离线，不再尝试连接检查
                if !wasOnline {
                    // 设备已经离线，不再尝试连接，直接返回离线状态
                    isOnline = false
                } else {
                    // 设备之前在线但现在没有收到广播，发送请求检查
                    isOnline = await checkPeerOnline(peer: currentPeer.peerID)
                }
            }
            
            // 关键：广播是设备在线的直接证据，优先于检查结果
            // 再次检查是否最近收到过广播（双重检查，避免竞态条件）
            let finalCheck = peerManager.getPeer(peerIDString)
            let finalRecentlySeen = finalCheck.map { Date().timeIntervalSince($0.lastSeenTime) < 30.0 } ?? false
            
            // 如果最近收到过广播，强制认为在线（广播是设备在线的直接证据）
            let finalIsOnline: Bool
            if finalRecentlySeen {
                finalIsOnline = true
                if !isOnline {
                    print("[SyncManager] ⚠️ 检查结果离线，但最近收到过广播，强制保持在线: \(peerIDString.prefix(12))...")
                }
            } else {
                // 没有最近广播，使用检查结果
                finalIsOnline = isOnline
            }
            
            if finalIsOnline != wasOnline {
                statusChanged = true
            }
            
            peerManager.updateOnlineStatus(peerIDString, isOnline: finalIsOnline)
        }
        
        if statusChanged {
            updateDeviceCounts()
        }
    }
    
    /// 检查单个对等点是否在线
    private func checkPeerOnline(peer: PeerID) async -> Bool {
        let peerIDString = peer.b58String
        
        // 注意：SyncManager 是 @MainActor，所以可以直接访问 peerManager
        
        // 首先检查设备是否已经标记为离线，如果已离线，不再尝试连接
        if !peerManager.isOnline(peerIDString) {
            // 设备已经离线，不再尝试连接
            return false
        }
        
        let isRegistered = peerManager.isRegistered(peerIDString)
        
        // 检查是否是新发现的（1分钟内）
        // 新发现的设备给更短的宽限期，加快离线检测
        let isRecentlyDiscovered: Bool = {
            if let peerInfo = peerManager.getPeer(peerIDString) {
                return Date().timeIntervalSince(peerInfo.discoveryTime) < 60.0
            }
            return false
        }()
        
        // 检查最近是否收到过广播（30秒内）
        // 如果最近收到过广播，说明设备在线，即使未注册也应该认为在线
        // 注意：广播间隔是1秒，30秒窗口可以容忍一定的UDP丢包
        let recentlySeen: Bool = {
            if let peerInfo = peerManager.getPeer(peerIDString) {
                return Date().timeIntervalSince(peerInfo.lastSeenTime) < 30.0
            }
            return false
        }()
        
        // 如果最近收到过广播，认为在线（广播是设备在线的直接证据）
        if recentlySeen {
            return true
        }
        
        // 如果未注册且不是新发现的，认为离线
        if !isRegistered && !isRecentlyDiscovered {
            return false
        }
        
        // 尝试发送轻量级请求验证设备是否在线
        // 缩短超时时间，加快离线检测
        do {
            let randomSyncID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).description
            let _: SyncResponse = try await sendSyncRequest(
                .getMST(syncID: randomSyncID),
                to: peer,
                peerID: peer.b58String,
                timeout: 3.0, // 从5秒缩短到3秒
                maxRetries: 1,
                folder: nil
            )
            return true
        } catch {
            let errorString = String(describing: error)
            
            // "Folder not found" 说明设备在线
            if errorString.contains("Folder not found") || errorString.contains("not found") || errorString.contains("does not exist") {
                return true
            }
            
            // 处理 peerNotFound 错误
            if errorString.contains("peerNotFound") || errorString.contains("BasicInMemoryPeerStore") {
                if isRegistered {
                    let isInConnectionWindow: Bool = {
                        if let peerInfo = peerManager.getPeer(peerIDString) {
                            return Date().timeIntervalSince(peerInfo.discoveryTime) < 300.0
                        }
                        return false
                    }()
                    return isInConnectionWindow || peerManager.isRegistered(peerIDString)
                } else {
                    return isRecentlyDiscovered
                }
            }
            
            // 连接相关错误（超时、连接失败等）
            if errorString.contains("TimedOut") || errorString.contains("timeout") ||
               errorString.contains("请求超时") ||
               errorString.contains("connection") || errorString.contains("Connection") ||
               errorString.contains("unreachable") {
                // 连接失败，将设备标记为离线
                await MainActor.run {
                    peerManager.updateOnlineStatus(peerIDString, isOnline: false)
                }
                return false
            }
            
            // 其他连接错误
            let isConnectionError = errorString.lowercased().contains("connect") ||
                                   errorString.lowercased().contains("network") ||
                                   errorString.lowercased().contains("unreachable") ||
                                   errorString.lowercased().contains("refused")
            
            if isConnectionError {
                return false
            }
            
            // 未知错误：新发现的保守认为在线
            return isRecentlyDiscovered
        }
    }
    
    /// 刷新文件夹的文件数量和文件夹数量统计（不触发同步，立即执行）
    func refreshFileCount(for folder: SyncFolder) {
        folderStatistics.refreshFileCount(for: folder)
    }
    
    func addFolder(_ folder: SyncFolder) {
        // 验证文件夹权限
        let fileManager = FileManager.default
        let folderPath = folder.localPath
        
        // 检查文件夹是否存在
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderPath.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            print("[SyncManager] ❌ 文件夹不存在或不是目录: \(folderPath.path)")
            updateFolderStatus(folder.id, status: .error, message: "文件夹不存在或不是目录")
            return
        }
        
        // 检查读取权限
        guard fileManager.isReadableFile(atPath: folderPath.path) else {
            print("[SyncManager] ❌ 没有读取权限: \(folderPath.path)")
            updateFolderStatus(folder.id, status: .error, message: "没有读取权限，请检查文件夹权限设置")
            return
        }
        
        // 检查写入权限（双向同步和上传模式需要）
        if folder.mode == .twoWay || folder.mode == .uploadOnly {
            guard fileManager.isWritableFile(atPath: folderPath.path) else {
                print("[SyncManager] ❌ 没有写入权限: \(folderPath.path)")
                updateFolderStatus(folder.id, status: .error, message: "没有写入权限，请检查文件夹权限设置")
                return
            }
        }
        
        // 验证 syncID 格式
        guard SyncIDManager.isValidSyncID(folder.syncID) else {
            print("[SyncManager] ❌ syncID 格式无效: \(folder.syncID)")
            updateFolderStatus(folder.id, status: .error, message: "syncID 格式无效（至少4个字符，只能包含字母和数字）")
            return
        }
        
        // 注册 syncID
        if !syncIDManager.registerSyncID(folder.syncID, folderID: folder.id) {
            print("[SyncManager] ⚠️ syncID 已存在或文件夹已关联其他 syncID: \(folder.syncID)")
            // 如果 syncID 已存在，检查是否是同一个文件夹
            if let existingInfo = syncIDManager.getSyncIDInfo(folder.syncID),
               existingInfo.folderID != folder.id {
                updateFolderStatus(folder.id, status: .error, message: "syncID 已被其他文件夹使用")
                return
            }
        }
        
        folders.append(folder)
        do {
            try StorageManager.shared.saveFolder(folder)
            print("[SyncManager] ✅ 文件夹配置已保存: \(folder.localPath.path) (syncID: \(folder.syncID))")
        } catch {
            print("[SyncManager] ❌ 无法保存文件夹配置: \(error)")
            print("[SyncManager] 错误详情: \(error.localizedDescription)")
            // 即使保存失败，也从内存中移除，避免不一致
            folders.removeAll { $0.id == folder.id }
            syncIDManager.unregisterSyncID(folder.syncID)
            updateFolderStatus(folder.id, status: .error, message: "无法保存配置: \(error.localizedDescription)")
            return
        }
        startMonitoring(folder)
        
        // 立即统计文件数量和文件夹数量
        print("[SyncManager] 📊 开始统计文件夹内容: \(folder.localPath.path)")
        refreshFileCount(for: folder)
        
        // Announce this folder on the network
        // 注意：如果 libp2p 没有配置 DHT 等发现服务，announce 会失败
        // 但这不影响 LANDiscovery 的自动发现功能，所以降级为警告
        Task {
            do {
                try await p2pNode.announce(service: "folder-sync-\(folder.syncID)")
                print("[SyncManager] ✅ 已发布服务: folder-sync-\(folder.syncID)")
            } catch {
                // 检查是否是发现服务不可用的错误
                let errorString = String(describing: error)
                if errorString.contains("noDiscoveryServicesAvailable") || errorString.contains("DiscoveryServices") {
                    // 这是预期的，因为我们使用 LANDiscovery 而不是 DHT
                    print("[SyncManager] ℹ️ 服务发布跳过（使用 LANDiscovery 自动发现）: folder-sync-\(folder.syncID)")
                } else {
                    print("[SyncManager] ⚠️ 无法发布服务: \(error)")
                    print("[SyncManager] 错误详情: \(error.localizedDescription)")
                }
            }
            
            // 等待一小段时间确保服务已发布，然后开始同步
            print("[SyncManager] ℹ️ 新文件夹已添加，准备开始同步...")
            
            // 延迟 3.5 秒后开始同步，确保：
            // P2PNode 已经等待了 2 秒，这里再等待 1.5 秒，总共约 3.5 秒
            // 1. 服务已发布
            // 2. 如果有现有 peer，可以立即同步
            // 3. 如果没有 peer，会等待 peer 发现后自动同步（通过 onPeerDiscovered 回调）
            try? await Task.sleep(nanoseconds: 2_500_000_000) // 等待 2.5 秒
            
            // 自动开始同步
            self.triggerSync(for: folder)
        }
    }
    
    func removeFolder(_ folder: SyncFolder) {
        stopMonitoring(folder)
        folders.removeAll { $0.id == folder.id }
        syncIDManager.unregisterSyncIDByFolderID(folder.id)
        // 防抖任务由 FolderMonitor 管理，停止监控时会自动取消
        try? StorageManager.shared.deleteFolder(folder.id)
    }
    
    func updateFolder(_ folder: SyncFolder) {
        guard let idx = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        // 重要：保留现有的统计值，避免覆盖为 nil
        var updatedFolder = folder
        let existingFolder = folders[idx]
        // 如果新 folder 的统计值为 nil，保留旧值
        if updatedFolder.fileCount == nil {
            updatedFolder.fileCount = existingFolder.fileCount
        }
        if updatedFolder.folderCount == nil {
            updatedFolder.folderCount = existingFolder.folderCount
        }
        if updatedFolder.totalSize == nil {
            updatedFolder.totalSize = existingFolder.totalSize
        }
        folders[idx] = updatedFolder
        try? StorageManager.shared.saveFolder(updatedFolder)
    }
    
    private func startMonitoring(_ folder: SyncFolder) {
        folderMonitor.startMonitoring(folder)
    }
    
    private func stopMonitoring(_ folder: SyncFolder) {
        folderMonitor.stopMonitoring(folder)
    }
    
    
    private let ignorePatterns = [".DS_Store", ".git/", "node_modules/", ".build/", ".swiftpm/"]
    
    func addUploadBytes(_ n: Int64) {
        uploadSamples.append((Date(), n))
        let cutoff = Date().addingTimeInterval(-speedWindow)
        uploadSamples.removeAll { $0.0 < cutoff }
        let sum = uploadSamples.reduce(Int64(0)) { $0 + $1.1 }
        uploadSpeedBytesPerSec = Double(sum) / speedWindow
    }
    
    func addDownloadBytes(_ n: Int64) {
        downloadSamples.append((Date(), n))
        let cutoff = Date().addingTimeInterval(-speedWindow)
        downloadSamples.removeAll { $0.0 < cutoff }
        let sum = downloadSamples.reduce(Int64(0)) { $0 + $1.1 }
        downloadSpeedBytesPerSec = Double(sum) / speedWindow
    }
    
    func isIgnored(_ path: String, folder: SyncFolder) -> Bool {
        let all = ignorePatterns + folder.excludePatterns
        for pattern in all {
            if Self.matchesIgnore(pattern: pattern, path: path) { return true }
        }
        return false
    }
    
    /// Simple .gitignore-style matching: exact, suffix (*.ext), dir/ (path contains), prefix.
    private static func matchesIgnore(pattern: String, path: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return false }
        if p.hasSuffix("/") {
            let dir = String(p.dropLast())
            if path.contains(dir + "/") || path.hasPrefix(dir + "/") { return true }
            return path == dir
        }
        if p.hasPrefix("*.") {
            let ext = String(p.dropFirst(2))
            // Only match files with the extension, not files with that exact name
            return path.hasSuffix("." + ext)
        }
        if path == p { return true }
        if path.hasSuffix("/" + p) { return true }
        if path.contains("/" + p + "/") { return true }
        return false
    }
    
    private func setupP2PHandlers() {
        // 设置原生网络服务的消息处理器
        p2pNode.nativeNetwork.messageHandler = { [weak self] request in
            guard let self = self else { return SyncResponse.error("Manager deallocated") }
            return try await self.handleSyncRequest(request)
        }
    }
    
    /// 处理同步请求（统一处理函数）
    private func handleSyncRequest(_ syncReq: SyncRequest) async throws -> SyncResponse {
        switch syncReq {
        case .getMST(let syncID):
            let folder = await MainActor.run { self.folders.first(where: { $0.syncID == syncID }) }
            if let folder = folder {
                let (mst, _, _, _) = await self.calculateFullState(for: folder)
                return .mstRoot(syncID: syncID, rootHash: mst.rootHash ?? "empty")
            }
            return .error("Folder not found")
            
        case .getFiles(let syncID):
            let folder = await MainActor.run { self.folders.first(where: { $0.syncID == syncID }) }
            if let folder = folder {
                let (_, metadata, _, _) = await self.calculateFullState(for: folder)
                return .files(syncID: syncID, entries: metadata)
            }
            return .error("Folder not found")
            
        case .getFileData(let syncID, let relativePath):
            let folder = await MainActor.run { self.folders.first(where: { $0.syncID == syncID }) }
            if let folder = folder {
                let fileURL = folder.localPath.appendingPathComponent(relativePath)
                
                // 检查文件是否正在写入
                let fileManager = FileManager.default
                if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                   let fileSize = attributes[.size] as? Int64,
                   fileSize == 0 {
                    // 检查文件修改时间
                    if let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                       let mtime = resourceValues.contentModificationDate {
                        let timeSinceModification = Date().timeIntervalSince(mtime)
                        let stabilityDelay: TimeInterval = 3.0 // 文件大小稳定3秒后才认为写入完成
                        if timeSinceModification < stabilityDelay {
                            // 文件可能是0字节且刚被修改，可能还在写入，等待一下
                            print("[SyncManager] ⏳ 文件可能正在写入，等待稳定: \(relativePath)")
                            try? await Task.sleep(nanoseconds: UInt64(stabilityDelay * 1_000_000_000))
                            
                            // 再次检查文件大小
                            if let newAttributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                               let newFileSize = newAttributes[.size] as? Int64,
                               newFileSize == 0 {
                                // 仍然是0字节，返回错误
                                return .error("文件可能正在写入中，请稍后重试")
                            }
                        }
                    }
                }
                
                let data = try Data(contentsOf: fileURL)
                return .fileData(syncID: syncID, path: relativePath, data: data)
            }
            return .error("Folder not found")
            
        case .putFileData(let syncID, let relativePath, let data, let vectorClock):
            let folder = await MainActor.run { self.folders.first(where: { $0.syncID == syncID }) }
            if let folder = folder {
                let fileURL = folder.localPath.appendingPathComponent(relativePath)
                let parentDir = fileURL.deletingLastPathComponent()
                let fileManager = FileManager.default
                
                if !fileManager.fileExists(atPath: parentDir.path) {
                    try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
                }
                
                guard fileManager.isWritableFile(atPath: parentDir.path) else {
                    return .error("没有写入权限: \(parentDir.path)")
                }
                
                try data.write(to: fileURL)
                if let vc = vectorClock {
                    // 合并 Vector Clock：保留本地 VC 的历史信息，同时更新远程 VC
                    var mergedVC = vc
                    if let localVC = StorageManager.shared.getVectorClock(syncID: syncID, path: relativePath) {
                        mergedVC.merge(with: localVC)
                    }
                    try? StorageManager.shared.setVectorClock(syncID: syncID, path: relativePath, mergedVC)
                }
                return .putAck(syncID: syncID, path: relativePath)
            }
            return .error("Folder not found")
            
        case .deleteFiles(let syncID, let paths):
            let folder = await MainActor.run { self.folders.first(where: { $0.syncID == syncID }) }
            if let folder = folder {
                let fileManager = FileManager.default
                
                for rel in paths {
                    let fileURL = folder.localPath.appendingPathComponent(rel)
                    // 如果文件存在，直接删除
                    if fileManager.fileExists(atPath: fileURL.path) {
                        try? fileManager.removeItem(at: fileURL)
                    }
                    // 删除 Vector Clock
                    try? StorageManager.shared.deleteVectorClock(syncID: syncID, path: rel)
                }
                return .deleteAck(syncID: syncID)
            }
            return .error("Folder not found")
            
        // 块级别增量同步请求
        case .getFileChunks(let syncID, let relativePath):
            return await handleGetFileChunks(syncID: syncID, path: relativePath)
            
        case .getChunkData(let syncID, let chunkHash):
            return await handleGetChunkData(syncID: syncID, chunkHash: chunkHash)
            
        case .putFileChunks(let syncID, let relativePath, let chunkHashes, let vectorClock):
            return await handlePutFileChunks(syncID: syncID, path: relativePath, chunkHashes: chunkHashes, vectorClock: vectorClock)
            
        case .putChunkData(let syncID, let chunkHash, let data):
            return await handlePutChunkData(syncID: syncID, chunkHash: chunkHash, data: data)
        }
    }
    
    // MARK: - 块级别增量同步处理
    
    /// 处理获取文件块列表请求
    private func handleGetFileChunks(syncID: String, path: String) async -> SyncResponse {
        let folder = await MainActor.run { self.folders.first(where: { $0.syncID == syncID }) }
        guard let folder = folder else {
            return .error("Folder not found")
        }
        
        let fileURL = folder.localPath.appendingPathComponent(path)
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .error("File not found")
        }
        
        do {
            // 使用 FastCDC 切分文件为块
            let cdc = FastCDC(min: 4096, avg: 16384, max: 65536)
            let chunks = try cdc.chunk(fileURL: fileURL)
            let chunkHashes = chunks.map { $0.hash }
            
            // 保存块到本地存储（用于后续去重）
            for chunk in chunks {
                if !StorageManager.shared.hasBlock(hash: chunk.hash) {
                    try StorageManager.shared.saveBlock(hash: chunk.hash, data: chunk.data)
                }
            }
            
            return .fileChunks(syncID: syncID, path: path, chunkHashes: chunkHashes)
        } catch {
            return .error("无法切分文件: \(error.localizedDescription)")
        }
    }
    
    /// 处理获取块数据请求
    private func handleGetChunkData(syncID: String, chunkHash: String) async -> SyncResponse {
        do {
            // 先从本地块存储获取
            if let data = try StorageManager.shared.getBlock(hash: chunkHash) {
                return .chunkData(syncID: syncID, chunkHash: chunkHash, data: data)
            }
            
            // 如果本地没有，尝试从文件重建（遍历所有文件查找包含该块的文件）
            let folder = await MainActor.run { self.folders.first(where: { $0.syncID == syncID }) }
            if let folder = folder {
                let fileManager = FileManager.default
                let enumerator = fileManager.enumerator(at: folder.localPath, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                
                if let enumerator = enumerator {
                    // 先收集所有文件 URL，避免在异步上下文中使用枚举器
                    var fileURLs: [URL] = []
                    while let fileURL = enumerator.nextObject() as? URL {
                        fileURLs.append(fileURL)
                    }
                    
                    // 然后处理收集到的文件
                    for fileURL in fileURLs {
                        guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                              resourceValues.isRegularFile == true else {
                            continue
                        }
                        
                        do {
                            let cdc = FastCDC(min: 4096, avg: 16384, max: 65536)
                            let chunks = try cdc.chunk(fileURL: fileURL)
                            
                            if let chunk = chunks.first(where: { $0.hash == chunkHash }) {
                                // 找到块，保存并返回
                                try StorageManager.shared.saveBlock(hash: chunkHash, data: chunk.data)
                                return .chunkData(syncID: syncID, chunkHash: chunkHash, data: chunk.data)
                            }
                        } catch {
                            continue
                        }
                    }
                }
            }
            
            return .error("块不存在: \(chunkHash)")
        } catch {
            return .error("获取块数据失败: \(error.localizedDescription)")
        }
    }
    
    /// 处理上传文件块列表请求
    private func handlePutFileChunks(syncID: String, path: String, chunkHashes: [String], vectorClock: VectorClock?) async -> SyncResponse {
        // 检查本地是否已有所有块
        let hasBlocks = StorageManager.shared.hasBlocks(hashes: chunkHashes)
        let missingHashes = chunkHashes.filter { !(hasBlocks[$0] ?? false) }
        
        if !missingHashes.isEmpty {
            // 返回缺失的块哈希列表，客户端需要上传这些块
            return .error("缺失块: \(missingHashes.joined(separator: ","))")
        }
        
        // 所有块都存在，重建文件
        let folder = await MainActor.run { self.folders.first(where: { $0.syncID == syncID }) }
        guard let folder = folder else {
            return .error("Folder not found")
        }
        
        let fileURL = folder.localPath.appendingPathComponent(path)
        let parentDir = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        
        do {
            // 确保父目录存在
            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            
            guard fileManager.isWritableFile(atPath: parentDir.path) else {
                return .error("没有写入权限: \(parentDir.path)")
            }
            
            // 从块重建文件
            var fileData = Data()
            for chunkHash in chunkHashes {
                guard let chunkData = try StorageManager.shared.getBlock(hash: chunkHash) else {
                    return .error("块不存在: \(chunkHash)")
                }
                fileData.append(chunkData)
            }
            
            // 写入文件
            try fileData.write(to: fileURL, options: [.atomic])
            
            // 更新 Vector Clock
            if let vc = vectorClock {
                var mergedVC = vc
                if let localVC = StorageManager.shared.getVectorClock(syncID: syncID, path: path) {
                    mergedVC.merge(with: localVC)
                }
                try? StorageManager.shared.setVectorClock(syncID: syncID, path: path, mergedVC)
            }
            
            return .fileChunksAck(syncID: syncID, path: path)
        } catch {
            return .error("重建文件失败: \(error.localizedDescription)")
        }
    }
    
    /// 处理上传块数据请求
    private func handlePutChunkData(syncID: String, chunkHash: String, data: Data) async -> SyncResponse {
        do {
            // 验证块哈希
            let hash = SHA256.hash(data: data)
            let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
            
            guard hashString == chunkHash else {
                return .error("块哈希不匹配: 期望 \(chunkHash)，实际 \(hashString)")
            }
            
            // 保存块
            try StorageManager.shared.saveBlock(hash: chunkHash, data: data)
            
            return .chunkAck(syncID: syncID, chunkHash: chunkHash)
        } catch {
            return .error("保存块失败: \(error.localizedDescription)")
        }
    }
    
    private func syncWithPeer(peer: PeerID, folder: SyncFolder) {
        syncEngine.syncWithPeer(peer: peer, folder: folder)
    }
    
    /// 统一的请求函数 - 使用原生 TCP
    func sendSyncRequest(
        _ message: SyncRequest,
        to peer: PeerID,
        peerID: String,
        timeout: TimeInterval = 90.0,
        maxRetries: Int = 3,
        folder: SyncFolder? = nil
    ) async throws -> SyncResponse {
        // 获取对等点地址
        let peerAddresses = await MainActor.run {
            return p2pNode.peerManager.getAddresses(for: peer.b58String)
        }
        
        // 从地址中提取第一个可用的 IP:Port 地址
        let addressStrings = peerAddresses.map { $0.description }
        guard let address = AddressConverter.extractFirstAddress(from: addressStrings) else {
            print("[SyncManager] ❌ [sendSyncRequest] 无法提取有效地址")
            throw NSError(domain: "SyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "对等点无可用地址"])
        }
        
        // 验证提取的地址
        let addressComponents = address.split(separator: ":")
        guard addressComponents.count == 2,
              let extractedIP = String(addressComponents[0]).removingPercentEncoding,
              let extractedPort = UInt16(String(addressComponents[1])),
              extractedPort > 0,
              extractedPort <= 65535,
              !extractedIP.isEmpty,
              extractedIP != "0.0.0.0" else {
            print("[SyncManager] ❌ [sendSyncRequest] 地址格式验证失败: \(address)")
            throw NSError(domain: "SyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "地址格式无效: \(address)"])
        }
        
        // 使用原生 TCP
        do {
            return try await p2pNode.nativeNetwork.sendRequest(
                message,
                to: address,
                timeout: timeout,
                maxRetries: maxRetries
            ) as SyncResponse
        } catch {
            // 注意：对等点应该已经注册（由 syncWithPeer 保证）
            // 如果请求失败，可能是网络问题或对等点暂时不可用
            // 不需要重新注册，直接抛出错误让调用者处理
            throw error
        }
    }
    
    
    @MainActor
    func addFolderPeer(_ syncID: String, peerID: String) {
        syncIDManager.addPeer(peerID, to: syncID)
        updatePeerCount(for: syncID)
    }
    
    @MainActor
    func removeFolderPeer(_ syncID: String, peerID: String) {
        syncIDManager.removePeer(peerID, from: syncID)
        updatePeerCount(for: syncID)
    }
    
    @MainActor
    private func updatePeerCount(for syncID: String) {
        if let index = folders.firstIndex(where: { $0.syncID == syncID }) {
            // 获取该 syncID 的所有 peer，但只统计在线的
            let peerIDs = syncIDManager.getPeers(for: syncID)
            let onlinePeerCount = peerIDs.filter { peerID in
                peerManager.isOnline(peerID)
            }.count
            
            // 创建新的文件夹对象以触发 @Published 更新
            var updatedFolder = folders[index]
            updatedFolder.peerCount = onlinePeerCount
            folders[index] = updatedFolder
            // 持久化保存更新
            do {
                try StorageManager.shared.saveFolder(updatedFolder)
            } catch {
                print("[SyncManager] ⚠️ 无法保存文件夹 peerCount 更新: \(error)")
            }
        }
    }
    
    func updateFolderStatus(_ id: UUID, status: SyncStatus, message: String? = nil, progress: Double = 0.0) {
        if let index = folders.firstIndex(where: { $0.id == id }) {
            // 创建新的文件夹对象以触发 @Published 更新
            var updatedFolder = folders[index]
            updatedFolder.status = status
            updatedFolder.lastSyncMessage = message
            updatedFolder.syncProgress = progress
            if status == .synced {
                updatedFolder.lastSyncedAt = Date()
            }
            folders[index] = updatedFolder
            
            // 持久化保存状态更新，确保重启后能恢复
            // 注意：保存时使用最新的 folder 对象，确保包含所有最新值（包括统计值）
            do {
                // 再次获取最新的 folder 对象，确保保存的是最新状态（包括统计值）
                if let latestFolder = folders.first(where: { $0.id == id }) {
                    try StorageManager.shared.saveFolder(latestFolder)
                } else {
                    // 如果找不到，使用 updatedFolder（虽然不太可能发生）
                    try StorageManager.shared.saveFolder(updatedFolder)
                }
            } catch {
                print("[SyncManager] ⚠️ 无法保存文件夹状态更新: \(error)")
                print("[SyncManager] 错误详情: \(error.localizedDescription)")
            }
        }
    }
    
    func triggerSync(for folder: SyncFolder) {
        // 检查是否有同步正在进行，避免重复触发
        // 注意：SyncManager 是 @MainActor，所以可以直接访问 syncInProgress
        let allPeers = peerManager.allPeers
        
        let hasSyncInProgress = allPeers.contains { peerInfo in
            let syncKey = "\(folder.syncID):\(peerInfo.peerIDString)"
            return syncInProgress.contains(syncKey)
        }
        
        if hasSyncInProgress {
            return
        }
        
        // 先更新状态，但不影响统计值（保留现有统计值）
        updateFolderStatus(folder.id, status: .syncing, message: "Scanning local files...")
        
        Task {
            // 1. Calculate the current state
            // 注意：这里计算状态是为了同步，统计更新应该通过 refreshFileCount 进行
            // 但为了同步需要，我们也需要更新统计值
            // 注意：这里更新统计值是为了同步开始时显示最新状态
            // SyncEngine 同步完成后也会更新统计值，但那是同步后的最终状态
            let (_, metadata, folderCount, totalSize) = await calculateFullState(for: folder)
            
            await MainActor.run {
                if let index = self.folders.firstIndex(where: { $0.id == folder.id }) {
                    // 创建新的文件夹对象以触发 @Published 更新
                    // 重要：原子性更新，一次性设置所有统计值，避免中间状态
                    var updatedFolder = self.folders[index]
                    
                    // 直接使用新计算的值（即使为0也是有效值）
                    // 原子性更新：一次性设置所有统计值，避免 UI 看到中间状态
                    updatedFolder.fileCount = metadata.count
                    updatedFolder.folderCount = folderCount
                    updatedFolder.totalSize = totalSize
                    
                    // 一次性替换，确保 UI 看到的是完整的新值
                    self.folders[index] = updatedFolder
                    // 手动触发 objectWillChange 以确保 UI 更新
                    self.objectWillChange.send()
                    // 持久化保存统计信息更新
                    do {
                        try StorageManager.shared.saveFolder(updatedFolder)
                    } catch {
                        print("[SyncManager] ⚠️ 无法保存文件夹统计信息更新: \(error)")
                    }
                }
            }
            
            // 2. Try sync with all registered peers (多点同步)
            // 需要在 MainActor 上访问 peerManager 和 registrationService
            let registeredPeers = await MainActor.run {
                let allPeers = self.peerManager.allPeers
                // 过滤出已注册且在线的对等点（离线设备不进行同步）
                return allPeers.filter { peerInfo in
                    self.p2pNode.registrationService.isRegistered(peerInfo.peerIDString) &&
                    self.peerManager.isOnline(peerInfo.peerIDString)
                }
            }
            
            if registeredPeers.isEmpty {
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .synced, message: "等待发现对等点...", progress: 0.0)
                }
            } else {
                // 多点同步：同时向所有已注册且在线的对等点同步
                for peerInfo in registeredPeers {
                    syncWithPeer(peer: peerInfo.peerID, folder: folder)
                }
            }
        }
    }
    
    private let indexingBatchSize = 50
    private let maxConcurrentFileProcessing = 4 // 最大并发文件处理数
    
    /// 流式计算文件哈希（避免一次性加载大文件到内存）
    nonisolated private func computeFileHash(fileURL: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }
        
        var hasher = SHA256()
        let bufferSize = 64 * 1024 // 64KB 缓冲区
        
        while true {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        
        let hash = hasher.finalize()
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    
    func calculateFullState(for folder: SyncFolder) async -> (MerkleSearchTree, [String: FileMetadata], folderCount: Int, totalSize: Int64) {
        return await folderStatistics.calculateFullState(for: folder)
    }
    
    /// 检查 syncID 是否存在于网络上的其他设备
    /// 通过尝试向已知对等点查询该 syncID 来验证
    func checkIfSyncIDExists(_ syncID: String) async -> Bool {
        // 验证 syncID 格式
        guard SyncIDManager.isValidSyncID(syncID) else {
            return false
        }
        
        // 首先检查本地是否已有该 syncID
        if syncIDManager.hasSyncID(syncID) {
            return true
        }
        
        // 检查远程设备
        let allPeers = peerManager.allPeers
        guard !allPeers.isEmpty else {
            return false
        }
        
        // 只检查最近收到过广播的对等点（30秒内），避免频繁连接
        for peerInfo in allPeers {
            // 检查是否最近收到过广播
            let recentlySeen = Date().timeIntervalSince(peerInfo.lastSeenTime) < 30.0
            guard recentlySeen else {
                continue
            }
            
            do {
                let response: SyncResponse = try await sendSyncRequest(.getMST(syncID: syncID), to: peerInfo.peerID, peerID: peerInfo.peerIDString, timeout: 3.0, maxRetries: 1, folder: nil)
                if case .mstRoot = response {
                    return true
                }
            } catch {
                continue
            }
        }
        
        return false
    }
    
    /// 获取总设备数量（包括自身）
    public var totalDeviceCount: Int {
        peerManager.allPeers.count + 1 // 包括自身
    }
    
    /// 在线设备数量（包括自身）
    public var onlineDeviceCount: Int {
        return onlineDeviceCountValue
    }
    
    /// 离线设备数量
    public var offlineDeviceCount: Int {
        return offlineDeviceCountValue
    }
    
    /// 更新设备统计（内部方法）
    /// 注意：统计逻辑与 allDevices 保持一致，只统计 .online 和 .offline 状态的设备
    func updateDeviceCounts() {
        // 先更新设备列表
        updateAllDevices()
        
        // 然后基于列表计算统计数据，确保一致性
        let deviceListOnline = allDevicesValue.filter { $0.status == "在线" && !$0.isLocal }.count
        let deviceListOffline = allDevicesValue.filter { $0.status == "离线" }.count
        
        let oldOnline = onlineDeviceCountValue
        let oldOffline = offlineDeviceCountValue
        
        onlineDeviceCountValue = deviceListOnline + 1 // 包括自身
        offlineDeviceCountValue = deviceListOffline
        
        // 如果计数发生变化，输出日志
        if oldOnline != onlineDeviceCountValue || oldOffline != offlineDeviceCountValue {
            print("[SyncManager] 📊 设备计数已更新: 在线=\(onlineDeviceCountValue) (之前: \(oldOnline)), 离线=\(offlineDeviceCountValue) (之前: \(oldOffline))")
        }
        
        // 更新所有文件夹的在线设备统计
        for folder in folders {
            updatePeerCount(for: folder.syncID)
        }
    }
    
    /// 获取所有设备列表（包括自身）
    /// 注意：只显示 .online 和 .offline 状态的设备，与 deviceCounts 保持一致
    public var allDevices: [DeviceInfo] {
        return allDevicesValue
    }
    
    /// 更新设备列表（内部方法）
    private func updateAllDevices() {
        var devices: [DeviceInfo] = []
        
        // 添加自身
        if let myPeerID = p2pNode.peerID {
            devices.append(DeviceInfo(
                peerID: myPeerID,
                isLocal: true,
                status: "在线"
            ))
        }
        
        // 添加其他设备（使用 peerManager，基于 deviceStatuses 作为权威状态源）
        // 只显示 .online 和 .offline 状态的设备，与 deviceCounts 统计逻辑保持一致
        for peerInfo in peerManager.allPeers {
            let status = peerManager.getDeviceStatus(peerInfo.peerIDString)
            // 只显示明确为在线或离线的设备，忽略 .connecting 和 .disconnected 状态
            if status == .online || status == .offline {
                devices.append(DeviceInfo(
                    peerID: peerInfo.peerIDString,
                    isLocal: false,
                    status: status == .online ? "在线" : "离线"
                ))
            }
        }
        
        // 只有当列表真正变化时才更新，避免不必要的 UI 刷新
        if devices != allDevicesValue {
            allDevicesValue = devices
        }
    }
    
    /// 检查是否应该为特定对等点和文件夹触发同步
    /// 避免频繁触发不必要的同步（比如在短时间内多次收到广播）
    /// - Parameters:
    ///   - peerID: 对等点 ID
    ///   - folder: 文件夹
    /// - Returns: 是否应该触发同步
    private func shouldSyncFolderWithPeer(peerID: String, folder: SyncFolder) -> Bool {
        let cooldownKey = "\(peerID):\(folder.syncID)"
        if let lastSyncTime = peerSyncCooldown[cooldownKey] {
            let timeSinceLastSync = Date().timeIntervalSince(lastSyncTime)
            // 如果该 peer-folder 对在最近30秒内已经同步过，阻止同步
            if timeSinceLastSync < peerSyncCooldownDuration {
                return false
            }
        }
        // 不在冷却期内，允许同步
        return true
    }
    
    /// 检查是否应该为对等点触发同步（用于判断是否有任何文件夹需要同步）
    /// 避免频繁触发不必要的同步（比如在短时间内多次收到广播）
    /// - Parameter peerID: 对等点 ID
    /// - Returns: 是否应该触发同步
    private func shouldTriggerSyncForPeer(peerID: String) -> Bool {
        // 检查该对等点与所有文件夹的同步冷却时间
        // 如果该对等点与任何文件夹不在冷却期内，允许触发同步（因为至少有一个文件夹需要同步）
        // 只有当该对等点与所有文件夹都在冷却期内时，才阻止同步
        guard !folders.isEmpty else {
            return true
        }
        
        // 检查是否所有文件夹都在冷却期内
        var allInCooldown = true
        for folder in folders {
            let cooldownKey = "\(peerID):\(folder.syncID)"
            if let lastSyncTime = peerSyncCooldown[cooldownKey] {
                let timeSinceLastSync = Date().timeIntervalSince(lastSyncTime)
                // 如果该文件夹在最近30秒内已经同步过，继续检查下一个
                if timeSinceLastSync < peerSyncCooldownDuration {
                    continue
                }
            }
            // 如果该文件夹不在冷却期内，说明至少有一个文件夹需要同步
            allInCooldown = false
            break
        }
        
        // 如果所有文件夹都在冷却期内，阻止同步；否则允许同步
        return !allInCooldown
    }
    
}

/// 设备信息结构
public struct DeviceInfo: Identifiable, Equatable {
    public let id = UUID()
    public let peerID: String
    public let isLocal: Bool
    public let status: String
    
    public static func == (lhs: DeviceInfo, rhs: DeviceInfo) -> Bool {
        return lhs.peerID == rhs.peerID && lhs.isLocal == rhs.isLocal && lhs.status == rhs.status
    }
}

