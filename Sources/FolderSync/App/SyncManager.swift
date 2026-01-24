import SwiftUI
import Combine
import Crypto
import LibP2P
import LibP2PCore

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
    
    // 文件监控防抖：syncID -> 防抖任务
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private let debounceDelay: TimeInterval = 2.0 // 2 秒防抖延迟
    
    // 设备统计（用于触发UI更新）
    @Published private(set) var onlineDeviceCountValue: Int = 1 // 包括自身，默认为1
    @Published private(set) var offlineDeviceCountValue: Int = 0
    
    public init() {
        // 运行环境检测
        print("\n[EnvironmentCheck] 开始环境检测...")
        let reports = EnvironmentChecker.runAllChecks()
        EnvironmentChecker.printReport(reports)
        
        // Load from storage
        do {
            let loadedFolders = try StorageManager.shared.getAllFolders()
            self.folders = loadedFolders
            print("[SyncManager] ✅ 成功加载 \(loadedFolders.count) 个同步文件夹配置")
            if loadedFolders.isEmpty {
                print("[SyncManager] ℹ️ 当前没有已保存的同步文件夹")
            } else {
                for folder in loadedFolders {
                    // 注册 syncID 到管理器
                    syncIDManager.registerSyncID(folder.syncID, folderID: folder.id)
                    print("[SyncManager]   - 文件夹: \(folder.localPath.path) (syncID: \(folder.syncID))")
                }
            }
        } catch {
            print("[SyncManager] ❌ 加载文件夹配置失败: \(error)")
            print("[SyncManager] 错误详情: \(error.localizedDescription)")
            self.folders = []
        }
        
        // 初始化设备统计（自身始终在线）
        updateDeviceCounts()
        
        // 监听 peerManager 的变化，同步更新 peers 数组（用于兼容性）
        Task { @MainActor in
            // 定期同步 peers 数组
            while !Task.isCancelled {
                let allPeers = peerManager.allPeers.map { $0.peerID }
                if self.peers != allPeers {
                    self.peers = allPeers
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 每秒同步一次
            }
        }
        
        Task { @MainActor in
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
                    self.peerManager.updateOnlineStatus(peerIDString, isOnline: true)
                    
                    if wasNew {
                        self.updateDeviceCounts()
                        // P2PNode 已经等待了 2 秒，这里再等待 1.5 秒，总共约 3.5 秒
                        // 确保对等点已完全注册到 libp2p peer store
                        for folder in self.folders {
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                self.syncWithPeer(peer: peer, folder: folder)
                            }
                        }
                    } else {
                        let wasOnline = self.peerManager.isOnline(peerIDString)
                        if !wasOnline {
                            self.updateDeviceCounts()
                        }
                    }
                }
            }
            
            // 启动 P2P 节点，如果失败则记录详细错误
            do {
                try await p2pNode.start()
                print("[SyncManager] ✅ P2P 节点启动成功")
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
            // 首次等待 60 秒，给设备足够时间完成连接和注册
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            
            while !Task.isCancelled {
                guard let self = self else { break }
                await self.checkAllPeersOnlineStatus()
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 每 30 秒检查一次
            }
        }
    }
    
    deinit {
        peerStatusCheckTask?.cancel()
    }
    
    /// 检查所有对等点的在线状态
    private func checkAllPeersOnlineStatus() async {
        guard p2pNode.app != nil else { return }
        
        let peersToCheck = peerManager.allPeers
        guard !peersToCheck.isEmpty else { return }
        
        for peerInfo in peersToCheck {
            let peerIDString = peerInfo.peerIDString
            let isOnline = await checkPeerOnline(peer: peerInfo.peerID)
            
            let wasOnline = peerInfo.isOnline
            peerManager.updateOnlineStatus(peerIDString, isOnline: isOnline)
            
            if isOnline != wasOnline {
                self.updateDeviceCounts()
            }
        }
    }
    
    /// 检查单个对等点是否在线
    private func checkPeerOnline(peer: PeerID) async -> Bool {
        guard let app = p2pNode.app else { return false }
        
        let peerIDString = peer.b58String
        let isRegistered = peerManager.isRegistered(peerIDString)
        
        // 检查是否是新发现的（2分钟内）
        let isRecentlyDiscovered: Bool = {
            if let peerInfo = peerManager.getPeer(peerIDString) {
                return Date().timeIntervalSince(peerInfo.discoveryTime) < 120.0
            }
            return false
        }()
        
        // 如果未注册且不是新发现的，认为离线
        if !isRegistered && !isRecentlyDiscovered {
            return false
        }
        
        // 尝试发送轻量级请求验证设备是否在线
        do {
            let randomSyncID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).description
            let _: SyncResponse = try await app.requestSync(
                .getMST(syncID: randomSyncID),
                to: peer,
                timeout: 5.0,
                maxRetries: 1
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
            print("[SyncManager] 📝 文件变化: \(path)")
            
            // 使用防抖机制，避免频繁同步
            let syncID = folder.syncID
            
            // 取消之前的防抖任务
            self?.debounceTasks[syncID]?.cancel()
            
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
            
            self?.debounceTasks[syncID] = debounceTask
        }
        monitor.start()
        monitors[folder.id] = monitor
    }
    
    private func stopMonitoring(_ folder: SyncFolder) {
        monitors[folder.id]?.stop()
        monitors.removeValue(forKey: folder.id)
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
        guard let app = p2pNode.app else { return }
        
        app.on("folder-sync/1.0.0") { [weak self] req -> SyncResponse in
            guard let self = self else { return .error("Manager deallocated") }
            do {
                let syncReq = try req.decode(SyncRequest.self)
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
                        
                        // 检查并创建父目录
                        if !fileManager.fileExists(atPath: parentDir.path) {
                            do {
                                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
                            } catch {
                                print("[SyncManager] ❌ 无法创建目录: \(parentDir.path) - \(error.localizedDescription)")
                                return .error("无法创建目录: \(error.localizedDescription)")
                            }
                        }
                        
                        // 检查写入权限
                        guard fileManager.isWritableFile(atPath: parentDir.path) else {
                            print("[SyncManager] ❌ 没有写入权限: \(parentDir.path)")
                            return .error("没有写入权限: \(parentDir.path)")
                        }
                        
                        do {
                            try data.write(to: fileURL)
                        } catch {
                            print("[SyncManager] ❌ 无法写入文件: \(fileURL.path) - \(error.localizedDescription)")
                            return .error("无法写入文件: \(error.localizedDescription)")
                        }
                        if let vc = vectorClock {
                            try? StorageManager.shared.setVectorClock(syncID: syncID, path: relativePath, vc)
                        }
                        return .putAck(syncID: syncID, path: relativePath)
                    }
                    return .error("Folder not found")
                    
                case .deleteFiles(let syncID, let paths):
                    let folder = await MainActor.run { self.folders.first(where: { $0.syncID == syncID }) }
                    if let folder = folder {
                        for rel in paths {
                            let fileURL = folder.localPath.appendingPathComponent(rel)
                            try? FileManager.default.removeItem(at: fileURL)
                            try? StorageManager.shared.deleteVectorClock(syncID: syncID, path: rel)
                        }
                        return .deleteAck(syncID: syncID)
                    }
                    return .error("Folder not found")
                }
            } catch {
                return .error(error.localizedDescription)
            }
        }
    }
    
    // TODO: 块级别同步 - 当前使用文件级别同步。要实现块级别：
    // 1. 使用 FastCDC 切分文件为块
    // 2. 修改 SyncRequest/SyncResponse 支持块传输
    // 3. 实现块去重和增量传输
    // 4. 文件重建逻辑
    // 这需要较大的协议改动
    
    private func syncWithPeer(peer: PeerID, folder: SyncFolder) {
        guard let app = p2pNode.app else {
            print("[SyncManager] ⚠️ 警告: P2P 节点未初始化，无法同步")
            return
        }
        let peerID = peer.b58String
        let syncKey = "\(folder.syncID):\(peerID)"
        
        Task { @MainActor in
            // 检查是否正在同步
            if self.syncInProgress.contains(syncKey) {
                print("[SyncManager] ⏭️ 同步已进行中，跳过重复同步: folder=\(folder.syncID), peer=\(peerID.prefix(12))...")
                return
            }
            
            // 标记为正在同步
            self.syncInProgress.insert(syncKey)
            
            // 使用 defer 确保在函数返回时移除同步标记
            defer {
                self.syncInProgress.remove(syncKey)
            }
            
            await self.performSync(peer: peer, folder: folder, peerID: peerID, app: app)
        }
    }
    
    private func performSync(peer: PeerID, folder: SyncFolder, peerID: String, app: Application) async {
        let startedAt = Date()
        do {
            guard !peerID.isEmpty else {
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .error, message: "PeerID 无效")
                }
                return
            }
            
            await MainActor.run {
                self.updateFolderStatus(folder.id, status: .syncing, message: "正在连接到 \(peerID.prefix(12))...", progress: 0.0)
            }
            
            // 获取远程 MST 根
            let rootRes: SyncResponse
            do {
                rootRes = try await app.requestSync(.getMST(syncID: folder.syncID), to: peer, timeout: 90.0, maxRetries: 3)
            } catch {
                let errorString = String(describing: error)
                
                // 处理 peerNotFound 错误：重新注册并重试
                if errorString.contains("peerNotFound") || errorString.contains("BasicInMemoryPeerStore") {
                    await MainActor.run {
                        self.updateFolderStatus(folder.id, status: .syncing, message: "重新注册对等点...", progress: 0.0)
                    }
                    
                    await p2pNode.retryPeerRegistration(peer: peer)
                    // retryPeerRegistration 已经等待了 2 秒，这里再等待 1 秒，总共约 3 秒
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    
                    do {
                        rootRes = try await app.requestSync(.getMST(syncID: folder.syncID), to: peer, timeout: 90.0, maxRetries: 2)
                    } catch {
                        await MainActor.run {
                            self.updateFolderStatus(folder.id, status: .error, message: "对等点注册失败，等待下次发现", progress: 0.0)
                        }
                        return // 重试失败，等待下次发现
                    }
                } else if let nsError = error as NSError?, nsError.code == 2 {
                    // 超时错误 - 这是真正的连接问题，应该报告
                    print("[SyncManager] ⚠️ 连接超时")
                    print("[SyncManager] 💡 提示: 对等点可能未响应，请检查:")
                    print("[SyncManager]   1. 网络连接是否正常")
                    print("[SyncManager]   2. 对等点是否在线")
                    print("[SyncManager]   3. 防火墙是否阻止了连接")
                    print("[SyncManager]   4. 两台设备是否在同一网络")
                    await MainActor.run {
                        self.updateFolderStatus(folder.id, status: .error, message: "连接超时: \(peerID.prefix(12))...")
                    }
                    return
                } else {
                    // 其他错误
                    await MainActor.run {
                        self.updateFolderStatus(folder.id, status: .error, message: "同步失败: \(error.localizedDescription)")
                    }
                    return
                }
            }
            
            if case .error(let errorMsg) = rootRes {
                // Remote doesn't have this folder
                // 这是正常的 - 对等点可能还没有这个 syncID（新创建的同步组）
                // 或者对等点确实没有此同步组
                // 这种情况不应该标记为错误，因为不是连接失败，而是对等点没有此同步组
                print("[SyncManager] ℹ️ 远程对等点没有此文件夹: \(folder.syncID)")
                print("[SyncManager]   错误信息: \(errorMsg)")
                print("[SyncManager]   对等点: \(peerID.prefix(12))...")
                print("[SyncManager] 💡 提示: 对等点可能还没有此同步组，这是正常的")
                print("[SyncManager]   等待其他设备也添加相同的 syncID 后会自动同步")
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
            }
            
            guard case .mstRoot(_, let remoteHash) = rootRes else { return }
            
            let (localMST, localMetadata, _) = await calculateFullState(for: folder)
            let currentPaths = Set(localMetadata.keys)
            let lastKnown = lastKnownLocalPaths[folder.syncID] ?? []
            let locallyDeleted = lastKnown.subtracting(currentPaths)
            if !lastKnown.isEmpty {
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
            
            let filesRes: SyncResponse = try await app.requestSync(.getFiles(syncID: folder.syncID), to: peer, timeout: 90.0, maxRetries: 2)
            guard case .files(_, let remoteEntries) = filesRes else { return }
            let myPeerID = p2pNode.peerID ?? ""
            var totalOps = 0
            var completedOps = 0
            
            enum DownloadAction {
                case skip
                case overwrite
                case conflict
            }
            func downloadAction(remote: FileMetadata, local: FileMetadata?) -> DownloadAction {
                guard let loc = local else { return .overwrite }
                if loc.hash == remote.hash { return .skip }
                if let rvc = remote.vectorClock, let lvc = loc.vectorClock, !rvc.versions.isEmpty || !lvc.versions.isEmpty {
                    let cmp = lvc.compare(to: rvc)
                    switch cmp {
                    case .antecedent: return .overwrite
                    case .successor, .equal: return .skip
                    case .concurrent: return .conflict
                    }
                }
                return remote.mtime > loc.mtime ? .overwrite : .skip
            }
            
            func shouldUpload(local: FileMetadata, remote: FileMetadata?) -> Bool {
                guard let rem = remote else { return true }
                if local.hash == rem.hash { return false }
                if let lvc = local.vectorClock, let rvc = rem.vectorClock, !lvc.versions.isEmpty || !rvc.versions.isEmpty {
                    let cmp = lvc.compare(to: rvc)
                    switch cmp {
                    case .successor: return true
                    case .antecedent, .equal: return false
                    case .concurrent: return local.mtime > rem.mtime
                    }
                }
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
            var changedFiles: [(String, FileMetadata)] = []
            var conflictFiles: [(String, FileMetadata)] = []
            if mode == .twoWay || mode == .downloadOnly {
                for (path, remoteMeta) in remoteEntries {
                    if deletedSet.contains(path) { continue }
                    switch downloadAction(remote: remoteMeta, local: localMetadata[path]) {
                    case .skip: break
                    case .overwrite: changedFiles.append((path, remoteMeta))
                    case .conflict: conflictFiles.append((path, remoteMeta))
                    }
                }
            }
            totalOps += changedFiles.count + conflictFiles.count
            
            // 4. Upload phase: find files to upload (skip if downloadOnly)
            var filesToUpload: [(String, FileMetadata)] = []
            if mode == .twoWay || mode == .uploadOnly {
                for (path, localMeta) in localMetadata {
                    if shouldUpload(local: localMeta, remote: remoteEntries[path]) {
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
                
                let delRes: SyncResponse = try await app.requestSync(.deleteFiles(syncID: folder.syncID, paths: Array(toDelete)), to: peer, timeout: 90.0, maxRetries: 2)
                if case .deleteAck = delRes {
                    for rel in toDelete {
                        let fileURL = folder.localPath.appendingPathComponent(rel)
                        try? FileManager.default.removeItem(at: fileURL)
                        try? StorageManager.shared.deleteVectorClock(syncID: folder.syncID, path: rel)
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
            let fileManager = FileManager.default
            
            for (path, remoteMeta) in changedFiles {
                let fileName = (path as NSString).lastPathComponent
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .syncing, message: "正在下载: \(fileName)...", progress: Double(completedOps) / Double(max(totalOps, 1)))
                }
                // 文件下载可能需要更长时间，使用 120 秒超时
                let dataRes: SyncResponse = try await app.requestSync(.getFileData(syncID: folder.syncID, path: path), to: peer, timeout: 180.0, maxRetries: 2)
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
                    let vc = remoteMeta.vectorClock ?? VectorClock()
                    try? StorageManager.shared.setVectorClock(syncID: folder.syncID, path: path, vc)
                    totalDownloadBytes += Int64(data.count)
                    await MainActor.run { self.addDownloadBytes(Int64(data.count)) }
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
                // 文件下载可能需要更长时间，使用 120 秒超时
                let dataRes: SyncResponse = try await app.requestSync(.getFileData(syncID: folder.syncID, path: path), to: peer, timeout: 180.0, maxRetries: 2)
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
                var vc = localMeta.vectorClock ?? VectorClock()
                vc.increment(for: myPeerID)
                try? StorageManager.shared.setVectorClock(syncID: folder.syncID, path: path, vc)
                let fileURL = folder.localPath.appendingPathComponent(path)
                
                // 检查文件是否存在和可读
                let fileManager = FileManager.default
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
                
                let data = try Data(contentsOf: fileURL)
                // 文件上传可能需要更长时间，使用 120 秒超时
                let putRes: SyncResponse = try await app.requestSync(.putFileData(syncID: folder.syncID, path: path, data: data, vectorClock: vc), to: peer, timeout: 180.0, maxRetries: 2)
                if case .error = putRes {
                    throw NSError(domain: "SyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upload failed for \(path)"])
                }
                totalUploadBytes += Int64(data.count)
                await MainActor.run { self.addUploadBytes(Int64(data.count)) }
                completedOps += 1
                
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .syncing, message: "上传完成: \(completedOps)/\(totalOps)", progress: Double(completedOps) / Double(max(totalOps, 1)))
                }
            }
            
            lastKnownLocalPaths[folder.syncID] = currentPaths
            await MainActor.run {
                self.updateFolderStatus(folder.id, status: .synced, message: "同步完成", progress: 1.0)
            }
            let totalBytes = totalDownloadBytes + totalUploadBytes
            let direction: SyncLog.Direction = mode == .uploadOnly ? .upload : (mode == .downloadOnly ? .download : .bidirectional)
            let log = SyncLog(syncID: folder.syncID, folderID: folder.id, peerID: peerID, direction: direction, bytesTransferred: totalBytes, filesCount: totalOps, startedAt: startedAt, completedAt: Date())
            try? StorageManager.shared.addSyncLog(log)
            } catch {
                print("[SyncManager] ❌ 同步失败: folder=\(folder.syncID), peer=\(peerID.prefix(8))")
                print("[SyncManager] 错误: \(error)")
                print("[SyncManager] 错误详情: \(error.localizedDescription)")
                if let nsError = error as NSError? {
                    print("[SyncManager] 错误域: \(nsError.domain), 错误码: \(nsError.code)")
                    if !nsError.userInfo.isEmpty {
                        print("[SyncManager] 用户信息: \(nsError.userInfo)")
                    }
                }
                
                await MainActor.run {
                    self.removeFolderPeer(folder.syncID, peerID: peerID)
                    let errorMessage = error.localizedDescription.isEmpty ? "同步失败: \(error)" : error.localizedDescription
                    self.updateFolderStatus(folder.id, status: .error, message: errorMessage)
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
            folders[index].peerCount = syncIDManager.getPeerCount(for: syncID)
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
        }
    }
    
    func triggerSync(for folder: SyncFolder) {
        // 检查是否有同步正在进行，避免重复触发
        let hasSyncInProgress = {
            let allPeers = peerManager.allPeers
            for peerInfo in allPeers {
                let syncKey = "\(folder.syncID):\(peerInfo.peerIDString)"
                if syncInProgress.contains(syncKey) {
                    return true
                }
            }
            return false
        }()
        
        if hasSyncInProgress {
            print("[SyncManager] ⏭️ 同步已进行中，跳过 triggerSync: \(folder.syncID)")
            return
        }
        
        updateFolderStatus(folder.id, status: .syncing, message: "Scanning local files...")
        
        Task {
            // 1. Calculate the current state
            let (mst, metadata, folderCount) = await calculateFullState(for: folder)
            
            await MainActor.run {
                if let index = self.folders.firstIndex(where: { $0.id == folder.id }) {
                    self.folders[index].fileCount = metadata.count
                    self.folders[index].folderCount = folderCount
                }
            }
            
            print("Folder \(folder.localPath.lastPathComponent) hash: \(mst.rootHash ?? "empty")")
            
            // 2. Try sync with all peers
            let allPeers = peerManager.allPeers.map { $0.peerID }
            if allPeers.isEmpty {
                print("[SyncManager] ℹ️ 暂无对等点，等待发现对等点后自动同步...")
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .synced, message: "等待发现对等点...", progress: 0.0)
                }
            } else {
                print("[SyncManager] 🔄 开始与 \(allPeers.count) 个对等点同步...")
                for peer in allPeers {
                    syncWithPeer(peer: peer, folder: folder)
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
                    do {
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
        guard !allPeers.isEmpty, let app = p2pNode.app else {
            return false
        }
        
        for peerInfo in allPeers {
            do {
                let response: SyncResponse = try await app.requestSync(.getMST(syncID: syncID), to: peerInfo.peerID, timeout: 30.0, maxRetries: 2)
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
    private func updateDeviceCounts() {
        let counts = peerManager.deviceCounts
        onlineDeviceCountValue = counts.online + 1 // 包括自身
        offlineDeviceCountValue = counts.offline
    }
    
    /// 获取所有设备列表（包括自身）
    public var allDevices: [DeviceInfo] {
        var devices: [DeviceInfo] = []
        
        // 添加自身
        if let myPeerID = p2pNode.peerID {
            devices.append(DeviceInfo(
                peerID: myPeerID,
                isLocal: true,
                status: "在线"
            ))
        }
        
        // 添加其他设备（使用 peerManager）
        for peerInfo in peerManager.allPeers {
            devices.append(DeviceInfo(
                peerID: peerInfo.peerIDString,
                isLocal: false,
                status: peerInfo.isOnline ? "在线" : "离线"
            ))
        }
        
        return devices
    }
}

/// 设备信息结构
public struct DeviceInfo: Identifiable {
    public let id = UUID()
    public let peerID: String
    public let isLocal: Bool
    public let status: String
}

