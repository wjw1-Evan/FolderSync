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
    
    private var monitors: [UUID: FSEventsMonitor] = [:]
    private var uploadSamples: [(Date, Int64)] = []
    private var downloadSamples: [(Date, Int64)] = []
    private let speedWindow: TimeInterval = 3
    private var lastKnownLocalPaths: [String: Set<String>] = [:]
    private var deletedPaths: [String: Set<String>] = [:]
    private var syncInProgress: Set<String> = [] // 正在同步的 (syncID, peerID) 组合，格式: "syncID:peerID"
    private var peerStatusCheckTask: Task<Void, Never>?
    private var peersSyncTask: Task<Void, Never>? // 定期同步 peers 数组的任务
    private var peerDiscoveryTask: Task<Void, Never>? // 对等点发现处理任务
    // 同步完成后的冷却时间：记录每个 syncID 的最后同步完成时间，在冷却期内忽略文件变化检测
    private var syncCooldown: [String: Date] = [:] // syncID -> 最后同步完成时间
    private let syncCooldownDuration: TimeInterval = 5.0 // 同步完成后5秒内忽略文件变化检测
    
    // 文件监控防抖：syncID -> 防抖任务
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private let debounceDelay: TimeInterval = 2.0 // 2 秒防抖延迟
    // 文件写入稳定性检测：记录文件路径和上次检查的大小
    private var fileStabilityCheck: [String: (size: Int64, lastCheck: Date)] = [:]
    private let fileStabilityDelay: TimeInterval = 3.0 // 文件大小稳定3秒后才认为写入完成
    
    // 设备统计（用于触发UI更新）
    @Published private(set) var onlineDeviceCountValue: Int = 1 // 包括自身，默认为1
    @Published private(set) var offlineDeviceCountValue: Int = 0
    @Published private(set) var allDevicesValue: [DeviceInfo] = [] // 设备列表（用于触发UI更新）
    
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
                    
                    if wasNew {
                        // 等待对等点注册完成后再同步
                        // 多点同步：当有多个对等点在线时，自动向所有已注册的对等点同步
                        Task { @MainActor in
                            // 使用 ensurePeerRegistered 确保注册完成
                            let registrationResult = await self.ensurePeerRegistered(peer: peer, peerID: peerIDString)
                            
                            if registrationResult.success {
                                // 向所有文件夹同步（多点同步）
                                for folder in self.folders {
                                    self.syncWithPeer(peer: peer, folder: folder)
                                }
                            } else {
                                print("[SyncManager] ⚠️ 新对等点注册失败，跳过同步: \(peerIDString.prefix(12))...")
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
            setupP2PHandlers()
            
            // Start monitoring and announcing all folders
            await MainActor.run {
                for folder in folders {
                    startMonitoring(folder)
                    // 启动后自动统计文件数量
                    refreshFileCount(for: folder)
                }
            }
            
            // 启动定期检查设备在线状态
            startPeerStatusMonitoring()
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
        // 取消所有防抖任务
        for task in debounceTasks.values {
            task.cancel()
        }
        debounceTasks.removeAll()
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
                // 没有最近收到广播，发送请求检查
                isOnline = await checkPeerOnline(peer: currentPeer.peerID)
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
            
            // 连接相关错误
            if errorString.contains("TimedOut") || errorString.contains("timeout") ||
               errorString.contains("connection") || errorString.contains("Connection") ||
               errorString.contains("unreachable") {
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
    
    /// 刷新文件夹的文件数量和文件夹数量统计（不触发同步）
    private func refreshFileCount(for folder: SyncFolder) {
        Task {
            print("[SyncManager] 📊 正在统计文件夹: \(folder.localPath.path)")
            let (_, metadata, folderCount) = await calculateFullState(for: folder)
            await MainActor.run {
                if let index = self.folders.firstIndex(where: { $0.id == folder.id }) {
                    self.folders[index].fileCount = metadata.count
                    self.folders[index].folderCount = folderCount
                    print("[SyncManager] ✅ 统计完成: \(metadata.count) 个文件, \(folderCount) 个文件夹")
                    // 持久化保存统计信息更新
                    do {
                        try StorageManager.shared.saveFolder(self.folders[index])
                    } catch {
                        print("[SyncManager] ⚠️ 无法保存文件夹统计信息更新: \(error)")
                    }
                } else {
                    print("[SyncManager] ⚠️ 警告: 无法找到文件夹索引，统计结果未更新")
                }
            }
        }
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
        // 取消防抖任务
        debounceTasks[folder.syncID]?.cancel()
        debounceTasks.removeValue(forKey: folder.syncID)
        try? StorageManager.shared.deleteFolder(folder.id)
    }
    
    func updateFolder(_ folder: SyncFolder) {
        guard let idx = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[idx] = folder
        try? StorageManager.shared.saveFolder(folder)
    }
    
    private func startMonitoring(_ folder: SyncFolder) {
        // Announce this folder on the network
        Task {
            try? await p2pNode.announce(service: "folder-sync-\(folder.syncID)")
        }
        
        let monitor = FSEventsMonitor(path: folder.localPath.path) { [weak self] path in
            // 检查是否在同步冷却期内（刚完成同步，忽略文件变化）
            if let lastSyncTime = self?.syncCooldown[folder.syncID],
               Date().timeIntervalSince(lastSyncTime) < (self?.syncCooldownDuration ?? 5.0) {
                return
            }
            
            // 检查文件是否正在被写入（文件大小是否稳定）
            Task { [weak self] in
                guard let self = self else { return }
                
                // 检查文件是否存在且是文件（不是目录）
                let fileManager = FileManager.default
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    // 是目录或文件不存在，直接触发同步
                    self.triggerSyncAfterDebounce(for: folder, syncID: folder.syncID)
                    return
                }
                
                // 检查文件是否正在写入
            let isStable = await self.checkFileStability(filePath: path)
            if isStable {
                // 文件已稳定，触发同步
                self.triggerSyncAfterDebounce(for: folder, syncID: folder.syncID)
            } else {
                // 文件正在写入，等待稳定后再触发同步
                await self.waitForFileStability(filePath: path, folder: folder, syncID: folder.syncID)
            }
            }
        }
        monitor.start()
        monitors[folder.id] = monitor
    }
    
    private func stopMonitoring(_ folder: SyncFolder) {
        monitors[folder.id]?.stop()
        monitors.removeValue(forKey: folder.id)
    }
    
    /// 检查文件是否稳定（文件大小在短时间内没有变化）
    private func checkFileStability(filePath: String) async -> Bool {
        let fileManager = FileManager.default
        
        guard let attributes = try? fileManager.attributesOfItem(atPath: filePath),
              let fileSize = attributes[.size] as? Int64 else {
            // 无法获取文件大小，认为不稳定
            return false
        }
        
        let now = Date()
        let fileKey = filePath
        
        // 检查是否有之前的记录
        if let previous = fileStabilityCheck[fileKey] {
            // 如果文件大小没有变化，且距离上次检查已超过稳定时间
            if previous.size == fileSize {
                let timeSinceLastCheck = now.timeIntervalSince(previous.lastCheck)
                if timeSinceLastCheck >= fileStabilityDelay {
                    // 文件大小稳定，清除记录
                    fileStabilityCheck.removeValue(forKey: fileKey)
                    return true
                }
            } else {
                // 文件大小变化了，更新记录
                fileStabilityCheck[fileKey] = (size: fileSize, lastCheck: now)
                return false
            }
        } else {
            // 首次检查，记录当前大小
            fileStabilityCheck[fileKey] = (size: fileSize, lastCheck: now)
            return false
        }
        
        return false
    }
    
    /// 等待文件写入完成（文件大小稳定）
    private func waitForFileStability(filePath: String, folder: SyncFolder, syncID: String) async {
        let maxWaitTime: TimeInterval = 60.0 // 最多等待60秒
        let checkInterval: TimeInterval = 1.0 // 每秒检查一次
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < maxWaitTime {
            // 等待一段时间后检查
            try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
            
            let isStable = await checkFileStability(filePath: filePath)
            if isStable {
                triggerSyncAfterDebounce(for: folder, syncID: syncID)
                return
            }
        }
        
        // 超时后仍然触发同步（可能文件很大，需要更长时间）
        triggerSyncAfterDebounce(for: folder, syncID: syncID)
    }
    
    /// 防抖触发同步
    private func triggerSyncAfterDebounce(for folder: SyncFolder, syncID: String) {
        // 取消之前的防抖任务
        debounceTasks[syncID]?.cancel()
        
        // 创建新的防抖任务
        let debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.debounceDelay ?? 2.0) * 1_000_000_000)
            
            guard !Task.isCancelled else { return }
            
            // 检查是否有同步正在进行
            let hasSyncInProgress = await MainActor.run {
                guard let self = self else { return false }
                let allPeers = self.peerManager.allPeers
                for peerInfo in allPeers {
                    let syncKey = "\(syncID):\(peerInfo.peerIDString)"
                    if self.syncInProgress.contains(syncKey) {
                        return true
                    }
                }
                return false
            }
            
            if hasSyncInProgress {
                print("[SyncManager] ⏭️ 同步已进行中，跳过防抖触发的同步: \(syncID)")
                return
            }
            
            print("[SyncManager] 🔄 防抖延迟结束，开始同步: \(syncID)")
            self?.triggerSync(for: folder)
        }
        
        debounceTasks[syncID] = debounceTask
    }
    
    private let ignorePatterns = [".DS_Store", ".git/", "node_modules/", ".build/", ".swiftpm/"]
    
    private func addUploadBytes(_ n: Int64) {
        uploadSamples.append((Date(), n))
        let cutoff = Date().addingTimeInterval(-speedWindow)
        uploadSamples.removeAll { $0.0 < cutoff }
        let sum = uploadSamples.reduce(Int64(0)) { $0 + $1.1 }
        uploadSpeedBytesPerSec = Double(sum) / speedWindow
    }
    
    private func addDownloadBytes(_ n: Int64) {
        downloadSamples.append((Date(), n))
        let cutoff = Date().addingTimeInterval(-speedWindow)
        downloadSamples.removeAll { $0.0 < cutoff }
        let sum = downloadSamples.reduce(Int64(0)) { $0 + $1.1 }
        downloadSpeedBytesPerSec = Double(sum) / speedWindow
    }
    
    private func isIgnored(_ path: String, folder: SyncFolder) -> Bool {
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
                let (mst, _, _) = await self.calculateFullState(for: folder)
                return .mstRoot(syncID: syncID, rootHash: mst.rootHash ?? "empty")
            }
            return .error("Folder not found")
            
        case .getFiles(let syncID):
            let folder = await MainActor.run { self.folders.first(where: { $0.syncID == syncID }) }
            if let folder = folder {
                let (_, metadata, _) = await self.calculateFullState(for: folder)
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
                        if timeSinceModification < fileStabilityDelay {
                            // 文件可能是0字节且刚被修改，可能还在写入，等待一下
                            print("[SyncManager] ⏳ 文件可能正在写入，等待稳定: \(relativePath)")
                            try? await Task.sleep(nanoseconds: UInt64(fileStabilityDelay * 1_000_000_000))
                            
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
                    // 删除文件（如果存在）
                    if fileManager.fileExists(atPath: fileURL.path) {
                        do {
                            try fileManager.removeItem(at: fileURL)
                        } catch {
                            print("[SyncManager] ⚠️ [handleSyncRequest] 删除文件失败: \(rel) - \(error)")
                            // 继续处理其他文件，不因单个文件失败而中断
                        }
                    }
                    // 删除 Vector Clock
                    do {
                        try StorageManager.shared.deleteVectorClock(syncID: syncID, path: rel)
                    } catch {
                        print("[SyncManager] ⚠️ [handleSyncRequest] 删除 Vector Clock 失败: \(rel) - \(error)")
                        // 继续处理其他文件
                    }
                }
                return .deleteAck(syncID: syncID)
            }
            return .error("Folder not found")
        }
    }
    
    // TODO: 块级别同步 - 当前使用文件级别同步。要实现块级别：
    // 1. 使用 FastCDC 切分文件为块
    // 2. 修改 SyncRequest/SyncResponse 支持块传输
    // 3. 实现块去重和增量传输
    // 4. 文件重建逻辑
    // 这需要较大的协议改动
    
    private func syncWithPeer(peer: PeerID, folder: SyncFolder) {
        let peerID = peer.b58String
        let syncKey = "\(folder.syncID):\(peerID)"
        
        Task { @MainActor in
            // 检查是否正在同步
            if self.syncInProgress.contains(syncKey) {
                return
            }
            
            // 确保对等点已注册（带重试机制）
            let registrationResult = await ensurePeerRegistered(peer: peer, peerID: peerID)
            
            guard registrationResult.success else {
                print("[SyncManager] ❌ [syncWithPeer] 对等点注册失败，跳过同步: \(peerID.prefix(12))...")
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .error, message: "对等点注册失败", progress: 0.0)
                }
                // 单个对等点注册失败时不执行同步
                return
            }
            
            // 标记为正在同步
            self.syncInProgress.insert(syncKey)
            
            // 使用 defer 确保在函数返回时移除同步标记
            defer {
                self.syncInProgress.remove(syncKey)
            }
            
            // 执行同步（此时对等点已确保注册成功）
            await self.performSync(peer: peer, folder: folder, peerID: peerID)
        }
    }
    
    /// 确保对等点已注册（带重试机制）
    /// - Returns: (success: Bool, isNewlyRegistered: Bool) - 是否成功，是否新注册
    @MainActor
    private func ensurePeerRegistered(peer: PeerID, peerID: String) async -> (success: Bool, isNewlyRegistered: Bool) {
        // 检查是否已注册
        if p2pNode.registrationService.isRegistered(peerID) {
            return (true, false)
        }
        
        print("[SyncManager] ⚠️ [ensurePeerRegistered] 对等点未注册，尝试注册: \(peerID.prefix(12))...")
        
        // 获取对等点地址
        let peerAddresses = p2pNode.peerManager.getAddresses(for: peerID)
        
        if peerAddresses.isEmpty {
            print("[SyncManager] ❌ [ensurePeerRegistered] 对等点无可用地址: \(peerID.prefix(12))...")
            return (false, false)
        }
        
        // 尝试注册
        let registered = p2pNode.registrationService.registerPeer(peerID: peer, addresses: peerAddresses)
        
        if !registered {
            print("[SyncManager] ❌ [ensurePeerRegistered] 对等点注册失败: \(peerID.prefix(12))...")
            return (false, false)
        }
        
        print("[SyncManager] ✅ [ensurePeerRegistered] 对等点注册成功，等待注册完成: \(peerID.prefix(12))...")
        
        // 等待注册完成（使用重试机制，最多等待 2 秒）
        let maxWaitTime: TimeInterval = 2.0
        let checkInterval: TimeInterval = 0.2
        let maxRetries = Int(maxWaitTime / checkInterval)
        
        for attempt in 1...maxRetries {
            try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
            
            if p2pNode.registrationService.isRegistered(peerID) {
                print("[SyncManager] ✅ [ensurePeerRegistered] 对等点注册确认成功: \(peerID.prefix(12))... (尝试 \(attempt)/\(maxRetries))")
                return (true, true)
            }
        }
        
        // 即使等待超时，如果注册状态显示正在注册中，也认为成功（可能是异步延迟）
        let registrationState = p2pNode.registrationService.getRegistrationState(peerID)
        if case .registering = registrationState {
            print("[SyncManager] ⚠️ [ensurePeerRegistered] 对等点正在注册中，继续尝试: \(peerID.prefix(12))...")
            return (true, true)
        }
        
        print("[SyncManager] ⚠️ [ensurePeerRegistered] 对等点注册等待超时，但继续尝试: \(peerID.prefix(12))...")
        return (true, true) // 即使超时也继续，让同步过程处理
    }
    
    /// 统一的请求函数 - 使用原生 TCP
    private func sendSyncRequest(
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
    
    private func performSync(peer: PeerID, folder: SyncFolder, peerID: String) async {
        let startedAt = Date()
        
        do {
            guard !peerID.isEmpty else {
                print("[SyncManager] ❌ [performSync] PeerID 无效")
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .error, message: "PeerID 无效")
                }
                return
            }
            
            // 注意：注册检查已在 syncWithPeer 中完成，这里不再重复检查
            // 如果到达这里，说明对等点已经注册成功
            
            await MainActor.run {
                self.updateFolderStatus(folder.id, status: .syncing, message: "正在连接到 \(peerID.prefix(12))...", progress: 0.0)
            }
            
            // 获取远程 MST 根
            // 首先获取对等点的地址
            let peerAddresses = await MainActor.run {
                return p2pNode.peerManager.getAddresses(for: peer.b58String)
            }
            if peerAddresses.isEmpty {
                print("[SyncManager] ⚠️ [performSync] 警告: 对等点没有可用地址")
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .error, message: "对等点无可用地址", progress: 0.0)
                }
                return
            }
            // 尝试使用原生网络服务（优先）
            let rootRes: SyncResponse
            do {
                // 从地址中提取第一个可用的 IP:Port 地址
                let addressStrings = peerAddresses.map { $0.description }
                
                guard let address = AddressConverter.extractFirstAddress(from: addressStrings) else {
                    let errorMsg = "无法从地址中提取 IP:Port（地址数: \(addressStrings.count)）"
                    print("[SyncManager] ❌ [performSync] \(errorMsg)")
                    throw NSError(domain: "SyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
                }
                
                // 验证提取的地址
                let addressComponents = address.split(separator: ":")
                guard addressComponents.count == 2,
                      let extractedIP = String(addressComponents[0]).removingPercentEncoding,
                      let extractedPort = UInt16(String(addressComponents[1])),
                      extractedPort > 0,
                      extractedPort <= 65535 else {
                    print("[SyncManager] ❌ [performSync] 地址格式验证失败: \(address)")
                    throw NSError(domain: "SyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "地址格式无效: \(address)"])
                }
                
                // 验证IP地址格式
                if extractedIP.isEmpty || extractedIP == "0.0.0.0" {
                    print("[SyncManager] ❌ [performSync] IP地址无效: '\(extractedIP)'")
                    throw NSError(domain: "SyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "IP地址无效: \(extractedIP)"])
                }
                
                // 使用原生网络服务发送请求
                // 缩短超时时间，加快失败检测
                rootRes = try await p2pNode.nativeNetwork.sendRequest(
                    .getMST(syncID: folder.syncID),
                    to: address,
                    timeout: 10.0, // 从90秒缩短到10秒，加快失败检测
                    maxRetries: 2  // 从5次减少到2次，避免长时间等待
                ) as SyncResponse
            } catch {
                let errorString = String(describing: error)
                print("[SyncManager] ❌ [performSync] 原生 TCP 请求失败: \(errorString)")
                
                // 注意：对等点应该已经注册（由 syncWithPeer 保证）
                // 如果连接失败，可能是网络问题或对等点暂时不可用
                // 不需要重新注册，因为注册状态应该仍然有效
                
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .error, message: "对等点连接失败，等待下次发现", progress: 0.0)
                }
                return
            }
            
            if case .error(let errorMsg) = rootRes {
                // Remote doesn't have this folder
                // 这是正常的 - 对等点可能还没有这个 syncID（新创建的同步组）
                // 或者对等点确实没有此同步组
                // 这种情况不应该标记为错误，因为不是连接失败，而是对等点没有此同步组
                // 不标记为错误，静默返回（这不是错误，而是对等点没有此同步组）
                await MainActor.run {
                    self.removeFolderPeer(folder.syncID, peerID: peerID)
                }
                return
            }
            
            // Peer confirmed to have this folder
            await MainActor.run {
                self.addFolderPeer(folder.syncID, peerID: peerID)
                self.syncIDManager.updateLastSyncedAt(folder.syncID)
                // 确认对等点在线（能够响应请求）
                self.peerManager.updateOnlineStatus(peerID, isOnline: true)
                self.updateDeviceCounts()
            }
            
            guard case .mstRoot(_, let remoteHash) = rootRes else {
                print("[SyncManager] ❌ [performSync] rootRes 不是 mstRoot 类型")
                return
            }
            
            let (localMST, localMetadata, _) = await calculateFullState(for: folder)
            
            let currentPaths = Set(localMetadata.keys)
            let lastKnown = lastKnownLocalPaths[folder.syncID] ?? []
            
            // 更严格的删除检测：只有当文件确实不存在于文件系统中时，才认为是删除
            // 避免因为文件被跳过（正在写入）而被误判为删除
            var locallyDeleted: Set<String> = []
            let fileManager = FileManager.default
            for path in lastKnown {
                // 如果文件不在当前路径中，检查文件是否真的不存在
                if !currentPaths.contains(path) {
                    let fileURL = folder.localPath.appendingPathComponent(path)
                    // 只有当文件确实不存在于文件系统中时，才认为是删除
                    if !fileManager.fileExists(atPath: fileURL.path) {
                        locallyDeleted.insert(path)
                    }
                    // 文件存在但不在 currentPaths 中，可能是被跳过了（正在写入）
                    // 不将其标记为删除，保留在 lastKnown 中
                }
            }
            
            // 更新 deletedPaths，但只添加真正删除的文件
            if !locallyDeleted.isEmpty {
                var dp = deletedPaths[folder.syncID] ?? []
                dp.formUnion(locallyDeleted)
                deletedPaths[folder.syncID] = dp
            }
            
            let mode = folder.mode
            
            if localMST.rootHash == remoteHash && locallyDeleted.isEmpty {
                lastKnownLocalPaths[folder.syncID] = currentPaths
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .synced, message: "Up to date", progress: 1.0)
                    self.syncIDManager.updateLastSyncedAt(folder.syncID)
                    // 确认对等点在线
                    self.peerManager.updateOnlineStatus(peerID, isOnline: true)
                    self.updateDeviceCounts()
                }
                let direction: SyncLog.Direction = mode == .uploadOnly ? .upload : (mode == .downloadOnly ? .download : .bidirectional)
                let log = SyncLog(syncID: folder.syncID, folderID: folder.id, peerID: peerID, direction: direction, bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date())
                try? StorageManager.shared.addSyncLog(log)
                return
            }
            
            // 2. Roots differ, get remote file list
            await MainActor.run {
                self.updateFolderStatus(folder.id, status: .syncing, message: "正在获取远程文件列表...", progress: 0.1)
            }
            
            let filesRes: SyncResponse
            do {
                filesRes = try await sendSyncRequest(
                    .getFiles(syncID: folder.syncID),
                    to: peer,
                    peerID: peerID,
                    timeout: 90.0,
                    maxRetries: 3,
                    folder: folder
                )
            } catch {
                print("[SyncManager] ❌ [performSync] 获取远程文件列表失败: \(error)")
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .error, message: "获取远程文件列表失败: \(error.localizedDescription)")
                }
                return
            }
            
            guard case .files(_, let remoteEntries) = filesRes else {
                print("[SyncManager] ❌ [performSync] filesRes 不是 files 类型")
                return
            }
            let myPeerID = p2pNode.peerID ?? ""
            var totalOps = 0
            var completedOps = 0
            var syncedFiles: [SyncLog.SyncedFileInfo] = [] // 记录同步的文件信息
            
            enum DownloadAction {
                case skip
                case overwrite
                case conflict
            }
            func downloadAction(remote: FileMetadata, local: FileMetadata?) -> DownloadAction {
                guard let loc = local else { 
                    return .overwrite 
                }
                // 优先检查 hash，如果相同则跳过
                if loc.hash == remote.hash { 
                    return .skip 
                }
                // 使用 Vector Clock 比较
                if let rvc = remote.vectorClock, let lvc = loc.vectorClock, !rvc.versions.isEmpty || !lvc.versions.isEmpty {
                    let cmp = lvc.compare(to: rvc)
                    switch cmp {
                    case .antecedent: 
                        return .overwrite
                    case .successor, .equal: 
                        return .skip
                    case .concurrent: 
                        print("[SyncManager] ⚠️ [downloadAction] VC 并发冲突，保存为冲突文件")
                        return .conflict
                    }
                }
                // 没有 Vector Clock，使用修改时间判断
                return remote.mtime > loc.mtime ? .overwrite : .skip
            }
            
            func shouldUpload(local: FileMetadata, remote: FileMetadata?) -> Bool {
                guard let rem = remote else { return true }
                // 如果 hash 相同，说明文件内容相同，不需要上传
                if local.hash == rem.hash {
                    return false
                }
                // 使用 Vector Clock 比较
                if let lvc = local.vectorClock, let rvc = rem.vectorClock, !lvc.versions.isEmpty || !rvc.versions.isEmpty {
                    let cmp = lvc.compare(to: rvc)
                    switch cmp {
                    case .successor:
                        return true
                    case .antecedent, .equal:
                        return false
                    case .concurrent:
                        // 并发冲突：两个版本都有修改，需要用户决定
                        // 为了保持一致性，使用修改时间判断，但应该标记为冲突
                        // 这里先使用 mtime 判断，后续可以改进为真正的冲突处理
                        let shouldUpload = local.mtime > rem.mtime
                        print("[SyncManager] ⚠️ [shouldUpload] VC 并发冲突，使用 mtime 判断: 本地=\(local.mtime), 远程=\(rem.mtime), 结果=\(shouldUpload)")
                        print("[SyncManager]   ⚠️ 注意：这是并发修改，可能需要手动解决冲突")
                        return shouldUpload
                    }
                }
                // 没有 Vector Clock，使用修改时间判断
                return local.mtime > rem.mtime
            }
            
            var deletedSet = deletedPaths[folder.syncID] ?? []
            let confirmed = deletedSet.filter { !remoteEntries.keys.contains($0) }
            for p in confirmed { deletedSet.remove(p) }
            if deletedSet.isEmpty {
                deletedPaths.removeValue(forKey: folder.syncID)
            } else {
                deletedPaths[folder.syncID] = deletedSet
            }
            
            // 3. Download phase (skip if uploadOnly); skip paths we've deleted
            // 使用 Set 来跟踪已决定下载的文件，避免重复
            var changedFilesSet: Set<String> = []
            var conflictFilesSet: Set<String> = []
            var changedFiles: [(String, FileMetadata)] = []
            var conflictFiles: [(String, FileMetadata)] = []
            if mode == .twoWay || mode == .downloadOnly {
                for (path, remoteMeta) in remoteEntries {
                    // 跳过已标记为删除的文件
                    if deletedSet.contains(path) { 
                        continue 
                    }
                    // 检查是否已经决定下载（避免重复）
                    if changedFilesSet.contains(path) || conflictFilesSet.contains(path) {
                        print("[SyncManager] ⚠️ [performSync] 文件已在待下载列表中，跳过重复: \(path)")
                        continue
                    }
                    switch downloadAction(remote: remoteMeta, local: localMetadata[path]) {
                    case .skip: break
                    case .overwrite: 
                        changedFilesSet.insert(path)
                        changedFiles.append((path, remoteMeta))
                    case .conflict: 
                        conflictFilesSet.insert(path)
                        conflictFiles.append((path, remoteMeta))
                    }
                }
            }
            totalOps += changedFiles.count + conflictFiles.count
            
            // 4. Upload phase: find files to upload (skip if downloadOnly)
            // 使用 Set 来跟踪已决定上传的文件，避免重复
            var filesToUploadSet: Set<String> = []
            var filesToUpload: [(String, FileMetadata)] = []
            if mode == .twoWay || mode == .uploadOnly {
                for (path, localMeta) in localMetadata {
                    // 跳过已标记为删除的文件
                    if locallyDeleted.contains(path) {
                        continue
                    }
                    // 检查是否已经决定上传（避免重复）
                    if filesToUploadSet.contains(path) {
                        print("[SyncManager] ⚠️ [performSync] 文件已在待上传列表中，跳过重复: \(path)")
                        continue
                    }
                    if shouldUpload(local: localMeta, remote: remoteEntries[path]) {
                        filesToUploadSet.insert(path)
                        filesToUpload.append((path, localMeta))
                    }
                }
            }
            totalOps += filesToUpload.count
            
            let toDelete = (mode == .twoWay || mode == .uploadOnly) ? locallyDeleted : []
            if !toDelete.isEmpty {
                totalOps += toDelete.count
            }
            
            // 更新总操作数并显示准备信息
            await MainActor.run {
                if totalOps > 0 {
                    self.updateFolderStatus(folder.id, status: .syncing, message: "准备同步 \(totalOps) 个操作...", progress: 0.2)
                }
            }
            
            // 删除文件
            if !toDelete.isEmpty {
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .syncing, message: "正在删除 \(toDelete.count) 个文件...", progress: Double(completedOps) / Double(max(totalOps, 1)))
                }
                
                let delRes: SyncResponse = try await sendSyncRequest(
                    .deleteFiles(syncID: folder.syncID, paths: Array(toDelete)),
                    to: peer,
                    peerID: peerID,
                    timeout: 90.0,
                    maxRetries: 3,
                    folder: folder
                )
                if case .deleteAck = delRes {
                    let fileManager = FileManager.default
                    for rel in toDelete {
                        let fileURL = folder.localPath.appendingPathComponent(rel)
                        let fileName = (rel as NSString).lastPathComponent
                        let pathDir = (rel as NSString).deletingLastPathComponent
                        let folderName = pathDir.isEmpty ? nil : (pathDir as NSString).lastPathComponent
                        
                        // 获取文件大小（如果文件还存在）
                        var fileSize: Int64 = 0
                        if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                           let size = attributes[.size] as? Int64 {
                            fileSize = size
                        }
                        
                        try? fileManager.removeItem(at: fileURL)
                        try? StorageManager.shared.deleteVectorClock(syncID: folder.syncID, path: rel)
                        
                        // 记录删除的文件信息
                        syncedFiles.append(SyncLog.SyncedFileInfo(
                            path: rel,
                            fileName: fileName,
                            folderName: folderName,
                            size: fileSize,
                            operation: .delete
                        ))
                    }
                    completedOps += toDelete.count
                }
            }
            
            if totalOps == 0 {
                lastKnownLocalPaths[folder.syncID] = currentPaths
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .synced, message: "Up to date", progress: 1.0)
                }
                return
            }
            
            // 5. Download changed files (overwrite)
            var totalDownloadBytes: Int64 = 0
            var totalUploadBytes: Int64 = 0
            
            for (path, remoteMeta) in changedFiles {
                let fileName = (path as NSString).lastPathComponent
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .syncing, message: "正在下载: \(fileName)...", progress: Double(completedOps) / Double(max(totalOps, 1)))
                }
                // 文件下载可能需要更长时间，使用 180 秒超时
                let dataRes: SyncResponse = try await sendSyncRequest(
                    .getFileData(syncID: folder.syncID, path: path),
                    to: peer,
                    peerID: peerID,
                    timeout: 180.0,
                    maxRetries: 3,
                    folder: folder
                )
                if case .fileData(_, _, let data) = dataRes {
                    let localURL = folder.localPath.appendingPathComponent(path)
                    let parentDir = localURL.deletingLastPathComponent()
                    
                    // 检查并创建父目录
                    if !fileManager.fileExists(atPath: parentDir.path) {
                        do {
                            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
                        } catch {
                            print("[SyncManager] ❌ 无法创建目录: \(parentDir.path) - \(error.localizedDescription)")
                            throw error
                        }
                    }
                    
                    // 检查写入权限
                    guard fileManager.isWritableFile(atPath: parentDir.path) else {
                        let error = NSError(domain: "SyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "没有写入权限: \(parentDir.path)"])
                        print("[SyncManager] ❌ 没有写入权限: \(parentDir.path)")
                        throw error
                    }
                    
                    do {
                        try data.write(to: localURL)
                    } catch {
                        print("[SyncManager] ❌ 无法写入文件: \(localURL.path) - \(error.localizedDescription)")
                        throw error
                    }
                    // 合并 Vector Clock：保留本地 VC 的历史信息，同时更新远程 VC
                    var vc = remoteMeta.vectorClock ?? VectorClock()
                    if let localVC = localMetadata[path]?.vectorClock {
                        vc.merge(with: localVC)
                    }
                    try? StorageManager.shared.setVectorClock(syncID: folder.syncID, path: path, vc)
                    totalDownloadBytes += Int64(data.count)
                    await MainActor.run { self.addDownloadBytes(Int64(data.count)) }
                    
                    // 记录同步的文件信息
                    let pathDir = (path as NSString).deletingLastPathComponent
                    let folderName = pathDir.isEmpty ? nil : (pathDir as NSString).lastPathComponent
                    syncedFiles.append(SyncLog.SyncedFileInfo(
                        path: path,
                        fileName: fileName,
                        folderName: folderName,
                        size: Int64(data.count),
                        operation: .download
                    ))
                }
                completedOps += 1
                
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .syncing, message: "下载完成: \(completedOps)/\(totalOps)", progress: Double(completedOps) / Double(max(totalOps, 1)))
                }
            }
            
            // 5b. Download conflict files (save to .conflict path, keep local)
            for (path, remoteMeta) in conflictFiles {
                let fileName = (path as NSString).lastPathComponent
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .syncing, message: "冲突文件: \(fileName)...", progress: Double(completedOps) / Double(max(totalOps, 1)))
                }
                // 文件下载可能需要更长时间，使用 180 秒超时
                let dataRes: SyncResponse = try await sendSyncRequest(
                    .getFileData(syncID: folder.syncID, path: path),
                    to: peer,
                    peerID: peerID,
                    timeout: 180.0,
                    maxRetries: 3,
                    folder: folder
                )
                if case .fileData(_, _, let data) = dataRes {
                    let pathDir = (path as NSString).deletingLastPathComponent
                    let parent = pathDir.isEmpty ? folder.localPath : folder.localPath.appendingPathComponent(pathDir)
                    let base = (fileName as NSString).deletingPathExtension
                    let ext = (fileName as NSString).pathExtension
                    let suffix = ext.isEmpty ? "" : ".\(ext)"
                    let conflictName = "\(base).conflict.\(String(peerID.prefix(8))).\(Int(remoteMeta.mtime.timeIntervalSince1970))\(suffix)"
                    let conflictURL = parent.appendingPathComponent(conflictName)
                    let fileManager = FileManager.default
                    
                    // 检查并创建父目录
                    if !fileManager.fileExists(atPath: parent.path) {
                        do {
                            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                        } catch {
                            print("[SyncManager] ❌ 无法创建冲突文件目录: \(parent.path) - \(error.localizedDescription)")
                            throw error
                        }
                    }
                    
                    // 检查写入权限
                    guard fileManager.isWritableFile(atPath: parent.path) else {
                        let error = NSError(domain: "SyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "没有写入权限: \(parent.path)"])
                        print("[SyncManager] ❌ 没有写入权限（冲突文件）: \(parent.path)")
                        throw error
                    }
                    
                    do {
                        try data.write(to: conflictURL)
                    } catch {
                        print("[SyncManager] ❌ 无法写入冲突文件: \(conflictURL.path) - \(error.localizedDescription)")
                        throw error
                    }
                    let relConflict = pathDir.isEmpty ? conflictName : "\(pathDir)/\(conflictName)"
                    let cf = ConflictFile(syncID: folder.syncID, relativePath: path, conflictPath: relConflict, remotePeerID: peerID)
                    try? StorageManager.shared.addConflict(cf)
                    totalDownloadBytes += Int64(data.count)
                    await MainActor.run { self.addDownloadBytes(Int64(data.count)) }
                    
                    // 记录冲突文件信息
                    let folderName = pathDir.isEmpty ? nil : (pathDir as NSString).lastPathComponent
                    syncedFiles.append(SyncLog.SyncedFileInfo(
                        path: path,
                        fileName: fileName,
                        folderName: folderName,
                        size: Int64(data.count),
                        operation: .conflict
                    ))
                }
                completedOps += 1
                
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .syncing, message: "冲突处理完成: \(completedOps)/\(totalOps)", progress: Double(completedOps) / Double(max(totalOps, 1)))
                }
            }
            
            // 6. Upload files to remote
            for (path, localMeta) in filesToUpload {
                let fileName = (path as NSString).lastPathComponent
                
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .syncing, message: "正在上传: \(fileName)...", progress: Double(completedOps) / Double(max(totalOps, 1)))
                }
                
                // 在上传之前，先重新读取文件，确保使用最新的文件内容
                let fileURL = folder.localPath.appendingPathComponent(path)
                let fileManager = FileManager.default
                
                // 检查文件是否存在和可读
                guard fileManager.fileExists(atPath: fileURL.path) else {
                    print("[SyncManager] ⚠️ 文件不存在（跳过上传）: \(fileURL.path)")
                    completedOps += 1
                    continue
                }
                
                guard fileManager.isReadableFile(atPath: fileURL.path) else {
                    print("[SyncManager] ⚠️ 文件无读取权限（跳过上传）: \(fileURL.path)")
                    completedOps += 1
                    continue
                }
                
                // 重新读取文件内容和 hash，确保使用最新数据
                let currentData: Data
                let currentHash: String
                do {
                    currentData = try Data(contentsOf: fileURL)
                    currentHash = SHA256.hash(data: currentData).compactMap { String(format: "%02x", $0) }.joined()
                    
                    // 如果文件 hash 已经变化（可能在上传过程中被修改），需要重新评估是否需要上传
                    if currentHash != localMeta.hash {
                        // 重新检查是否需要上传（使用新的 hash）
                        let newMeta = FileMetadata(hash: currentHash, mtime: localMeta.mtime, vectorClock: localMeta.vectorClock)
                        if let remoteMeta = remoteEntries[path] {
                            // 如果新 hash 与远程相同，不需要上传
                            if currentHash == remoteMeta.hash {
                                completedOps += 1
                                continue
                            }
                            // 重新评估是否应该上传
                            if !shouldUpload(local: newMeta, remote: remoteMeta) {
                                completedOps += 1
                                continue
                            }
                        }
                        // 文件已修改且需要上传，继续使用新的数据
                    }
                } catch {
                    print("[SyncManager] ❌ 无法读取文件（跳过上传）: \(fileURL.path) - \(error)")
                    completedOps += 1
                    continue
                }
                
                // 更新 Vector Clock（在上传之前）
                var vc = localMeta.vectorClock ?? VectorClock()
                vc.increment(for: myPeerID)
                try? StorageManager.shared.setVectorClock(syncID: folder.syncID, path: path, vc)
                
                // 使用重新读取的数据
                let data = currentData
                
                // 文件上传可能需要更长时间，使用 180 秒超时
                let putRes: SyncResponse = try await sendSyncRequest(
                    .putFileData(syncID: folder.syncID, path: path, data: data, vectorClock: vc),
                    to: peer,
                    peerID: peerID,
                    timeout: 180.0,
                    maxRetries: 3,
                    folder: folder
                )
                if case .error(let errorMsg) = putRes {
                    print("[SyncManager] ❌ [performSync] 上传失败: \(fileName) - \(errorMsg)")
                    throw NSError(domain: "SyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upload failed for \(path): \(errorMsg)"])
                }
                totalUploadBytes += Int64(data.count)
                await MainActor.run { self.addUploadBytes(Int64(data.count)) }
                completedOps += 1
                
                // 记录上传的文件信息
                let pathDir = (path as NSString).deletingLastPathComponent
                let folderName = pathDir.isEmpty ? nil : (pathDir as NSString).lastPathComponent
                syncedFiles.append(SyncLog.SyncedFileInfo(
                    path: path,
                    fileName: fileName,
                    folderName: folderName,
                    size: Int64(data.count),
                    operation: .upload
                ))
                
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .syncing, message: "上传完成: \(completedOps)/\(totalOps)", progress: Double(completedOps) / Double(max(totalOps, 1)))
                }
            }
            
            // 同步完成后，重新计算本地状态，确保 lastKnownLocalPaths 准确
            // 这很重要，因为同步过程中可能有文件被跳过（正在写入）
            let (finalMST, finalMetadata, _) = await calculateFullState(for: folder)
            let finalPaths = Set(finalMetadata.keys)
            lastKnownLocalPaths[folder.syncID] = finalPaths
            
            let totalBytes = totalDownloadBytes + totalUploadBytes
            
            await MainActor.run {
                self.updateFolderStatus(folder.id, status: .synced, message: "同步完成", progress: 1.0)
                self.syncIDManager.updateLastSyncedAt(folder.syncID)
                // 同步成功，更新对等点在线状态
                self.peerManager.updateOnlineStatus(peerID, isOnline: true)
                self.updateDeviceCounts()
                // 设置同步冷却时间，防止立即触发新的同步
                self.syncCooldown[folder.syncID] = Date()
            }
            let direction: SyncLog.Direction = mode == .uploadOnly ? .upload : (mode == .downloadOnly ? .download : .bidirectional)
            let log = SyncLog(syncID: folder.syncID, folderID: folder.id, peerID: peerID, direction: direction, bytesTransferred: totalBytes, filesCount: totalOps, startedAt: startedAt, completedAt: Date(), syncedFiles: syncedFiles.isEmpty ? nil : syncedFiles)
            try? StorageManager.shared.addSyncLog(log)
        } catch {
            let duration = Date().timeIntervalSince(startedAt)
            print("[SyncManager] ❌ [performSync] 同步失败!")
            print("[SyncManager]   文件夹: \(folder.syncID)")
            print("[SyncManager]   对等点: \(peerID.prefix(12))...")
            print("[SyncManager]   耗时: \(String(format: "%.2f", duration)) 秒")
            print("[SyncManager]   错误类型: \(type(of: error))")
            print("[SyncManager]   错误描述: \(error)")
            if let nsError = error as NSError? {
                print("[SyncManager]   NSError code: \(nsError.code)")
                print("[SyncManager]   NSError domain: \(nsError.domain)")
                if !nsError.userInfo.isEmpty {
                    print("[SyncManager]   NSError userInfo: \(nsError.userInfo)")
                }
            }
            
            await MainActor.run {
                self.removeFolderPeer(folder.syncID, peerID: peerID)
                let errorMessage = error.localizedDescription.isEmpty ? "同步失败: \(error)" : error.localizedDescription
                self.updateFolderStatus(folder.id, status: .error, message: errorMessage)
                
                // 检查是否是连接错误，如果是则更新设备状态
                let errorString = String(describing: error)
                let isConnectionError = errorString.contains("peerNotFound") ||
                                       errorString.contains("TimedOut") ||
                                       errorString.contains("timeout") ||
                                       errorString.contains("connection") ||
                                       errorString.contains("Connection") ||
                                       errorString.contains("unreachable") ||
                                       errorString.contains("refused")
                
                if isConnectionError {
                    // 连接错误，但不立即标记为离线，等待定期检查确认
                    print("[SyncManager] ⚠️ 同步失败（连接错误），等待定期检查确认设备状态: \(peerID.prefix(12))...")
                }
            }
            let log = SyncLog(syncID: folder.syncID, folderID: folder.id, peerID: peerID, direction: .bidirectional, bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: nil, errorMessage: error.localizedDescription)
            do {
                try StorageManager.shared.addSyncLog(log)
            } catch {
                print("[SyncManager] ⚠️ 无法保存同步日志: \(error)")
            }
        }
    }
    
    @MainActor
    private func addFolderPeer(_ syncID: String, peerID: String) {
        syncIDManager.addPeer(peerID, to: syncID)
        updatePeerCount(for: syncID)
    }
    
    @MainActor
    private func removeFolderPeer(_ syncID: String, peerID: String) {
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
            
            folders[index].peerCount = onlinePeerCount
            // 持久化保存更新
            do {
                try StorageManager.shared.saveFolder(folders[index])
            } catch {
                print("[SyncManager] ⚠️ 无法保存文件夹 peerCount 更新: \(error)")
            }
        }
    }
    
    private func updateFolderStatus(_ id: UUID, status: SyncStatus, message: String? = nil, progress: Double = 0.0) {
        if let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index].status = status
            folders[index].lastSyncMessage = message
            folders[index].syncProgress = progress
            if status == .synced {
                folders[index].lastSyncedAt = Date()
            }
            
            // 持久化保存状态更新，确保重启后能恢复
            do {
                try StorageManager.shared.saveFolder(folders[index])
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
        
        updateFolderStatus(folder.id, status: .syncing, message: "Scanning local files...")
        
        Task {
            // 1. Calculate the current state
            let (_, metadata, folderCount) = await calculateFullState(for: folder)
            
            await MainActor.run {
                if let index = self.folders.firstIndex(where: { $0.id == folder.id }) {
                    self.folders[index].fileCount = metadata.count
                    self.folders[index].folderCount = folderCount
                    // 持久化保存统计信息更新
                    do {
                        try StorageManager.shared.saveFolder(self.folders[index])
                    } catch {
                        print("[SyncManager] ⚠️ 无法保存文件夹统计信息更新: \(error)")
                    }
                }
            }
            
            // 2. Try sync with all registered peers (多点同步)
            // 需要在 MainActor 上访问 peerManager 和 registrationService
            let registeredPeers = await MainActor.run {
                let allPeers = self.peerManager.allPeers
                // 过滤出已注册的对等点
                return allPeers.filter { peerInfo in
                    self.p2pNode.registrationService.isRegistered(peerInfo.peerIDString)
                }
            }
            
            if registeredPeers.isEmpty {
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .synced, message: "等待发现对等点...", progress: 0.0)
                }
            } else {
                // 多点同步：同时向所有已注册的对等点同步
                for peerInfo in registeredPeers {
                    syncWithPeer(peer: peerInfo.peerID, folder: folder)
                }
            }
        }
    }
    
    private let indexingBatchSize = 50
    
    private func calculateFullState(for folder: SyncFolder) async -> (MerkleSearchTree, [String: FileMetadata], folderCount: Int) {
        let url = folder.localPath
        let syncID = folder.syncID
        let mst = MerkleSearchTree()
        var metadata: [String: FileMetadata] = [:]
        var folderCount = 0
        let fileManager = FileManager.default
        var processedInBatch = 0
        
        let resourceKeys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .contentModificationDateKey]
        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles])
        
        while let fileURL = enumerator?.nextObject() as? URL {
            do {
                // 检查文件是否可访问
                guard fileManager.isReadableFile(atPath: fileURL.path) else {
                    print("[SyncManager] ⚠️ 跳过无读取权限的文件: \(fileURL.path)")
                    continue
                }
                
                let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                var relativePath = fileURL.path.replacingOccurrences(of: url.path, with: "")
                if relativePath.hasPrefix("/") { relativePath.removeFirst() }
                
                if isIgnored(relativePath, folder: folder) { continue }
                
                if resourceValues.isDirectory == true {
                    // 统计文件夹数量（不包括根目录本身）
                    if !relativePath.isEmpty {
                        folderCount += 1
                    }
                } else {
                    // 处理文件 - 检查文件是否可读
                    // 先检查文件是否正在写入（文件大小是否稳定）
                    let fileKey = fileURL.path
                    if let stability = fileStabilityCheck[fileKey] {
                        let timeSinceLastCheck = Date().timeIntervalSince(stability.lastCheck)
                        // 如果文件在最近3秒内被修改过，可能还在写入，跳过此文件
                        if timeSinceLastCheck < fileStabilityDelay {
                            continue
                        }
                    }
                    
                    do {
                        // 检查文件大小，如果为0且文件很新，可能还在写入
                        let fileAttributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                        if let fileSize = fileAttributes[.size] as? Int64,
                           fileSize == 0 {
                            // 检查文件修改时间，如果文件在最近3秒内被修改，可能还在写入
                            if let mtime = resourceValues.contentModificationDate {
                                let timeSinceModification = Date().timeIntervalSince(mtime)
                                if timeSinceModification < fileStabilityDelay {
                                    print("[SyncManager] ⏳ 跳过可能正在写入的0字节文件: \(relativePath)")
                                    continue
                                }
                            }
                        }
                        
                        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                        let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
                        let mtime = resourceValues.contentModificationDate ?? Date()
                        let vc = StorageManager.shared.getVectorClock(syncID: syncID, path: relativePath) ?? VectorClock()
                        
                        mst.insert(key: relativePath, value: hash)
                        metadata[relativePath] = FileMetadata(hash: hash, mtime: mtime, vectorClock: vc)
                        processedInBatch += 1
                        if processedInBatch >= indexingBatchSize {
                            processedInBatch = 0
                            await Task.yield()
                        }
                    } catch {
                        // 文件读取失败（可能是权限问题或文件被锁定）
                        print("[SyncManager] ⚠️ 无法读取文件（跳过）: \(fileURL.path) - \(error.localizedDescription)")
                        continue
                    }
                }
            } catch {
                // 资源值获取失败（可能是权限问题）
                print("[SyncManager] ⚠️ 无法获取文件属性（跳过）: \(fileURL.path) - \(error.localizedDescription)")
                continue
            }
        }
        return (mst, metadata, folderCount)
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
        
        for peerInfo in allPeers {
            do {
                let response: SyncResponse = try await sendSyncRequest(.getMST(syncID: syncID), to: peerInfo.peerID, peerID: peerInfo.peerIDString, timeout: 30.0, maxRetries: 2, folder: nil)
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
    private func updateDeviceCounts() {
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

