import SwiftUI
import Combine
import Crypto
import LibP2P
import LibP2PCore

@MainActor
public class SyncManager: ObservableObject {
    @Published var folders: [SyncFolder] = []
    @Published var peers: [PeerID] = [] // PeerIDs
    @Published var folderPeers: [String: Set<String>] = [:] // SyncID -> PeerIDs
    @Published var uploadSpeedBytesPerSec: Double = 0
    @Published var downloadSpeedBytesPerSec: Double = 0
    let p2pNode = P2PNode()
    
    private var monitors: [UUID: FSEventsMonitor] = [:]
    private var uploadSamples: [(Date, Int64)] = []
    private var downloadSamples: [(Date, Int64)] = []
    private let speedWindow: TimeInterval = 3
    private var lastKnownLocalPaths: [String: Set<String>] = [:]
    private var deletedPaths: [String: Set<String>] = [:]
    
    // 设备在线状态跟踪
    private var peerOnlineStatus: [String: Bool] = [:] // PeerID (b58String) -> 是否在线
    private var peerStatusCheckTask: Task<Void, Never>?
    
    public init() {
        // 运行环境检测
        print("\n[EnvironmentCheck] 开始环境检测...")
        let reports = EnvironmentChecker.runAllChecks()
        EnvironmentChecker.printReport(reports)
        
        // Load from storage
        self.folders = (try? StorageManager.shared.getAllFolders()) ?? []
        
        Task { @MainActor in
            p2pNode.onPeerDiscovered = { [weak self] peer in
                Task { @MainActor in
                    guard let self = self else { return }
                    let peerIDString = peer.b58String
                    
                    // 验证 PeerID
                    print("[SyncManager] 🔍 收到对等点发现通知:")
                    print("[SyncManager]   - PeerID (完整): \(peerIDString)")
                    print("[SyncManager]   - PeerID (长度): \(peerIDString.count) 字符")
                    
                    if peerIDString.isEmpty {
                        print("[SyncManager] ❌ 错误: 收到的 PeerID 为空，忽略")
                        return
                    }
                    
                    if !self.peers.contains(where: { $0.b58String == peerIDString }) {
                        print("[SyncManager] ✅ 新对等点已添加: \(peerIDString.prefix(12))...")
                        self.peers.append(peer)
                        
                        // 标记为新发现的设备为在线状态
                        self.peerOnlineStatus[peerIDString] = true
                        
                        // 当发现新对等点时，延迟同步以确保对等点已正确注册到 libp2p peer store
                        // 这很重要，因为对等点需要时间被添加到 peer store
                        // 注意：P2PNode.connectToDiscoveredPeer 会：
                        //   1. 等待 1.5 秒（确保环境就绪）
                        //   2. 调用 callback 通知 SyncManager（T=1.5）
                        //   3. 再等待 1 秒（确保 libp2p 处理完成，T=2.5）
                        // SyncManager 收到通知后等待 1 秒，在 T=2.5 开始同步
                        // 此时 P2PNode 已经等待了 2.5 秒，确保 peer store 已更新
                        for folder in self.folders {
                            Task {
                                // 延迟 1 秒，确保对等点已完全注册到 libp2p peer store
                                // P2PNode 已经等待了 2.5 秒（1.5 + 1），这里再等待 1 秒
                                // 通知发生在 T=1.5，同步开始于 T=2.5，此时 peer store 应该已更新
                                print("[SyncManager] ⏳ 等待对等点注册到 libp2p peer store...")
                                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
                                print("[SyncManager] 🔄 开始同步: folder=\(folder.syncID), peer=\(peerIDString.prefix(12))...")
                                self.syncWithPeer(peer: peer, folder: folder)
                            }
                        }
                    } else {
                        print("[SyncManager] ℹ️ 对等点已存在，跳过: \(peerIDString.prefix(12))...")
                        // 更新在线状态（设备重新出现）
                        self.peerOnlineStatus[peerIDString] = true
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
        // 取消之前的任务
        peerStatusCheckTask?.cancel()
        
        // 启动新的定期检查任务
        peerStatusCheckTask = Task { [weak self] in
            // 首次等待 30 秒，给设备足够的时间完成连接和注册
            // 从 60 秒减少到 30 秒，避免设备状态更新过慢
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30秒
            
            while !Task.isCancelled {
                guard let self = self else { break }
                await self.checkAllPeersOnlineStatus()
                
                // 之后每 30 秒检查一次设备在线状态
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30秒
            }
        }
    }
    
    /// 停止定期检查设备在线状态（清理资源）
    deinit {
        peerStatusCheckTask?.cancel()
    }
    
    /// 检查所有对等点的在线状态
    private func checkAllPeersOnlineStatus() async {
        guard let app = p2pNode.app else {
            print("[SyncManager] ⚠️ P2P 节点未初始化，跳过设备状态检查")
            return
        }
        
        let peersToCheck = await MainActor.run { self.peers }
        
        if peersToCheck.isEmpty {
            print("[SyncManager] ℹ️ 没有对等点需要检查")
            return
        }
        
        print("[SyncManager] 🔍 开始检查 \(peersToCheck.count) 个设备的在线状态...")
        
        for peer in peersToCheck {
            let peerIDString = peer.b58String
            let isOnline = await checkPeerOnline(peer: peer)
            
            await MainActor.run {
                let wasOnline = peerOnlineStatus[peerIDString] ?? false
                peerOnlineStatus[peerIDString] = isOnline
                
                if isOnline != wasOnline {
                    // 修复 Bug 1: 正确显示旧状态（wasOnline 为 true 时显示"在线"，false 时显示"离线"）
                    print("[SyncManager] 📡 设备状态变化: \(peerIDString.prefix(12))... \(wasOnline ? "在线" : "离线") -> \(isOnline ? "在线" : "离线")")
                    
                    // 如果设备离线，只更新状态为离线，不从列表中移除
                    // 这样用户可以继续看到离线设备，并知道它们的状态
                    if !isOnline {
                        print("[SyncManager] 📴 设备已标记为离线: \(peerIDString.prefix(12))...")
                        print("[SyncManager] 💡 设备仍保留在列表中，状态显示为离线")
                    } else {
                        print("[SyncManager] ✅ 设备已重新上线: \(peerIDString.prefix(12))...")
                    }
                } else {
                    print("[SyncManager] ✅ 设备状态未变化: \(peerIDString.prefix(12))... \(isOnline ? "在线" : "离线")")
                }
            }
        }
        
        print("[SyncManager] ✅ 设备状态检查完成")
    }
    
    /// 检查单个对等点是否在线
    private func checkPeerOnline(peer: PeerID) async -> Bool {
        guard let app = p2pNode.app else {
            return false
        }
        
        let peerIDString = peer.b58String
        
        // 尝试发送一个轻量级的请求来检查设备是否在线
        // 使用一个不存在的 syncID，如果设备在线会返回 "Folder not found"（这是正常的）
        // 如果设备离线，会返回连接错误或超时
        do {
            // 使用一个随机生成的 syncID，确保不存在
            // 这样可以避免误判（如果恰好有设备使用了 "__ping_check__" 这个 syncID）
            let randomSyncID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).description
            let _: SyncResponse = try await app.requestSync(
                .getMST(syncID: randomSyncID),
                to: peer,
                timeout: 5.0,  // 5秒超时
                maxRetries: 1  // 只重试1次
            )
            // 如果成功返回（虽然不应该，因为 syncID 不存在），说明设备在线
            print("[SyncManager] ✅ 设备 \(peerIDString.prefix(12))... 在线（意外返回了响应）")
            return true
        } catch {
            let errorString = String(describing: error)
            
            // 如果是 "Folder not found" 错误，说明设备在线（只是没有这个 syncID）
            if errorString.contains("Folder not found") || 
               errorString.contains("not found") ||
               errorString.contains("does not exist") {
                print("[SyncManager] ✅ 设备 \(peerIDString.prefix(12))... 在线（返回 Folder not found，这是正常的）")
                return true
            }
            
            // 如果是连接错误、超时或 peerNotFound，说明设备离线
            if errorString.contains("peerNotFound") || 
               errorString.contains("BasicInMemoryPeerStore") ||
               errorString.contains("TimedOut") || 
               errorString.contains("timeout") ||
               errorString.contains("connection") ||
               errorString.contains("Connection") ||
               errorString.contains("unreachable") {
                print("[SyncManager] ❌ 设备 \(peerIDString.prefix(12))... 离线（错误: \(errorString)）")
                return false
            }
            
            // 其他错误，保守地认为设备可能在线（可能是其他原因导致的错误）
            print("[SyncManager] ⚠️ 检查设备 \(peerIDString.prefix(12))... 时出现未知错误: \(errorString)")
            print("[SyncManager] 💡 保守地认为设备在线")
            return true // 保守地认为在线
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
        
        folders.append(folder)
        do {
            try StorageManager.shared.saveFolder(folder)
        } catch {
            print("[SyncManager] ❌ 无法保存文件夹配置: \(error)")
            print("[SyncManager] 错误详情: \(error.localizedDescription)")
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
            
            // 对于新创建的同步组，不应该立即尝试与所有对等点同步
            // 因为对等点可能还没有这个 syncID
            // 只有在以下情况才应该同步：
            // 1. 加入现有同步组（syncID 已存在于网络上）
            // 2. 对等点主动发现并请求同步
            
            // 如果是加入现有同步组，等待验证后再同步
            // 如果是创建新同步组，等待其他对等点发现后再同步
            print("[SyncManager] ℹ️ 新文件夹已添加，等待对等点发现或主动同步")
        }
        
        // 如果是加入现有同步组，触发同步
        // 如果是创建新同步组，不立即同步，等待其他设备发现
        // triggerSync(for: folder) // 注释掉，避免创建新同步组时立即同步
    }
    
    func removeFolder(_ folder: SyncFolder) {
        stopMonitoring(folder)
        folders.removeAll { $0.id == folder.id }
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
            print("File changed at: \(path)")
            self?.triggerSync(for: folder)
            
            // Notify peers
            if let peers = self?.peers {
                for peer in peers {
                    self?.syncWithPeer(peer: peer, folder: folder)
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
        
        Task {
            let startedAt = Date()
            do {
                // 验证 PeerID
                print("[SyncManager] 📡 开始同步:")
                print("[SyncManager]   - 文件夹 syncID: \(folder.syncID)")
                print("[SyncManager]   - 对等点 PeerID (完整): \(peerID)")
                print("[SyncManager]   - 对等点 PeerID (长度): \(peerID.count) 字符")
                print("[SyncManager]   - 对等点 PeerID (显示): \(peerID.prefix(12))...")
                
                if peerID.isEmpty {
                    print("[SyncManager] ❌ 错误: PeerID 为空，无法同步")
                    await MainActor.run {
                        self.updateFolderStatus(folder.id, status: .error, message: "PeerID 无效")
                    }
                    return
                }
                
                // 验证 PeerID 长度（正常的 libp2p PeerID 应该是 50+ 字符）
                if peerID.count < 40 {
                    print("[SyncManager] ⚠️ 警告: PeerID 长度异常短 (\(peerID.count) 字符)，可能不完整")
                    print("[SyncManager]   期望长度: 50+ 字符")
                    print("[SyncManager]   实际 PeerID: \(peerID)")
                }
                
                // 验证 PeerID 格式（应该以 "12D3KooW" 开头）
                if !peerID.hasPrefix("12D3KooW") {
                    print("[SyncManager] ⚠️ 警告: PeerID 格式可能不正确")
                    print("[SyncManager]   期望前缀: 12D3KooW...")
                    print("[SyncManager]   实际前缀: \(peerID.prefix(12))...")
                }
                
                // 验证 PeerID 对象
                print("[SyncManager]   - 使用 PeerID 对象: \(peer.b58String)")
                if peer.b58String != peerID {
                    print("[SyncManager] ⚠️ 警告: PeerID 字符串与对象不一致!")
                    print("[SyncManager]   字符串: \(peerID)")
                    print("[SyncManager]   对象: \(peer.b58String)")
                }
                
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .syncing, message: "Connecting to \(peerID.prefix(12))...")
                }
                
                // 1. Get remote MST root
                // 使用较长的超时时间，因为首次连接可能需要时间
                // 增加重试次数，因为首次连接建立可能需要多次尝试
                let rootRes: SyncResponse
                do {
                    // 再次验证 peer 对象
                    print("[SyncManager] 🔗 准备连接到对等点:")
                    print("[SyncManager]   - Peer 对象 b58String: \(peer.b58String)")
                    print("[SyncManager]   - Peer 对象长度: \(peer.b58String.count) 字符")
                    
                    rootRes = try await app.requestSync(.getMST(syncID: folder.syncID), to: peer, timeout: 90.0, maxRetries: 3)
                } catch {
                    print("[SyncManager] ❌ 获取远程 MST 根失败: \(error)")
                    print("[SyncManager] 错误详情: \(error.localizedDescription)")
                    
                    // 检查是否是 peerNotFound 错误
                    let errorString = String(describing: error)
                    if errorString.contains("peerNotFound") || errorString.contains("BasicInMemoryPeerStore") {
                        print("[SyncManager] ⚠️ 对等点未在 libp2p peer store 中找到")
                        print("[SyncManager] 💡 可能的原因:")
                        print("[SyncManager]   1. 对等点地址未正确注册到 libp2p")
                        print("[SyncManager]   2. 对等点可能已离线")
                        print("[SyncManager]   3. 网络发现可能尚未完成")
                        print("[SyncManager] 💡 建议: 等待几秒后重试，或检查对等点是否在线")
                        print("[SyncManager] ⏳ 等待 5 秒后重试连接，给 libp2p 更多时间处理对等点注册...")
                        
                        // 等待更长时间后重试（给 libp2p 时间发现对等点并更新 peer store）
                        // 从 3 秒增加到 5 秒，确保对等点有足够时间注册
                        // 这可能是因为对等点正在被注册，需要更多时间完成
                        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
                        print("[SyncManager] 🔄 重试连接...")
                        do {
                            rootRes = try await app.requestSync(.getMST(syncID: folder.syncID), to: peer, timeout: 90.0, maxRetries: 2)
                        } catch {
                            let retryErrorString = String(describing: error)
                            // 如果重试仍然失败，检查是否是 peerNotFound
                            if retryErrorString.contains("peerNotFound") || retryErrorString.contains("BasicInMemoryPeerStore") {
                                print("[SyncManager] ⚠️ 重试后仍然无法找到对等点")
                                print("[SyncManager] 💡 这可能是因为对等点尚未完全注册到 libp2p peer store")
                                print("[SyncManager] 💡 建议: 等待更长时间或检查对等点是否在线")
                                // 不标记为错误，因为对等点可能正在注册中
                                // 等待下一次定期检查或重新发现
                                return
                            }
                            // 其他错误，标记为错误
                            await MainActor.run {
                                self.updateFolderStatus(folder.id, status: .error, message: "无法连接到对等点: \(peerID.prefix(12))...")
                            }
                            return
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
                    }
                    let direction: SyncLog.Direction = mode == .uploadOnly ? .upload : (mode == .downloadOnly ? .download : .bidirectional)
                    let log = SyncLog(syncID: folder.syncID, folderID: folder.id, peerID: peerID, direction: direction, bytesTransferred: 0, filesCount: 0, startedAt: startedAt, completedAt: Date())
                    try? StorageManager.shared.addSyncLog(log)
                    return
                }
                
                // 2. Roots differ, get remote file list
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
                    let delRes: SyncResponse = try await app.requestSync(.deleteFiles(syncID: folder.syncID, paths: Array(toDelete)), to: peer, timeout: 90.0, maxRetries: 2)
                    if case .error = delRes { /* log but continue */ }
                }
                
                if totalOps == 0 && toDelete.isEmpty {
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
                    let fileName = URL(fileURLWithPath: path).lastPathComponent
                    await MainActor.run {
                        self.updateFolderStatus(folder.id, status: .syncing, message: "Downloading \(fileName)", progress: totalOps > 0 ? Double(completedOps) / Double(totalOps) : 1.0)
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
                }
                
                // 5b. Download conflict files (save to .conflict path, keep local)
                for (path, remoteMeta) in conflictFiles {
                    let fileName = URL(fileURLWithPath: path).lastPathComponent
                    await MainActor.run {
                        self.updateFolderStatus(folder.id, status: .syncing, message: "Conflict: \(fileName)", progress: totalOps > 0 ? Double(completedOps) / Double(totalOps) : 1.0)
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
                }
                
                // 6. Upload files to remote
                for (path, localMeta) in filesToUpload {
                    let fileName = URL(fileURLWithPath: path).lastPathComponent
                    await MainActor.run {
                        self.updateFolderStatus(folder.id, status: .syncing, message: "Uploading \(fileName)", progress: totalOps > 0 ? Double(completedOps) / Double(totalOps) : 1.0)
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
                }
                
                lastKnownLocalPaths[folder.syncID] = currentPaths
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .synced, message: "Sync complete", progress: 1.0)
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
    }
    
    @MainActor
    private func addFolderPeer(_ syncID: String, peerID: String) {
        var currentPeers = folderPeers[syncID] ?? Set()
        if !currentPeers.contains(peerID) {
            currentPeers.insert(peerID)
            folderPeers[syncID] = currentPeers
            updatePeerCount(for: syncID)
        }
    }
    
    @MainActor
    private func removeFolderPeer(_ syncID: String, peerID: String) {
        var currentPeers = folderPeers[syncID] ?? Set()
        if currentPeers.contains(peerID) {
            currentPeers.remove(peerID)
            folderPeers[syncID] = currentPeers
            updatePeerCount(for: syncID)
        }
    }
    
    @MainActor
    private func updatePeerCount(for syncID: String) {
        if let index = folders.firstIndex(where: { $0.syncID == syncID }) {
            folders[index].peerCount = folderPeers[syncID]?.count ?? 0
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
            if peers.isEmpty {
                print("SyncManager: No peers to sync with for folder \(folder.syncID)")
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .synced, message: "No peers found", progress: 0.0)
                }
            } else {
                for peer in peers {
                    syncWithPeer(peer: peer, folder: folder)
                }
            }
        }
    }
    
    private static let indexingBatchSize = 50
    
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
                        if processedInBatch >= Self.indexingBatchSize {
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
        // 首先检查本地是否已有该 syncID
        if folders.contains(where: { $0.syncID == syncID }) {
            print("[SyncManager] ✅ syncID 在本地已存在: \(syncID)")
            return true
        }
        
        // 如果 syncID 太短，认为无效
        guard syncID.count >= 4 else {
            print("[SyncManager] ❌ syncID 太短（至少需要 4 个字符）: \(syncID)")
            return false
        }
        
        // 如果没有已知的对等点，无法验证
        // 不等待，直接返回 false（因为无法确认 syncID 是否存在）
        // 这样可以避免每次添加文件夹时的延迟
        if peers.isEmpty || p2pNode.app == nil {
            print("[SyncManager] ⚠️ 暂无已知对等点，无法验证 syncID: \(syncID)")
            print("[SyncManager] 💡 提示: 请确保:")
            print("[SyncManager]   1. 两台设备都在同一局域网内")
            print("[SyncManager]   2. 另一台设备已启动并配置了相同的 syncID")
            print("[SyncManager]   3. 等待几秒让设备自动发现")
            // 返回 false，表示无法确认 syncID 是否存在
            // 但这不影响添加文件夹，系统会自动处理
            return false
        }
        
        guard let app = p2pNode.app else {
            print("[SyncManager] ❌ P2P 节点未初始化")
            return false
        }
        
        print("[SyncManager] 🔍 开始验证 syncID: \(syncID)")
        print("[SyncManager]   已知对等点数量: \(peers.count)")
        
        // 向所有已知对等点查询该 syncID
        // 如果任何一个对等点有该 syncID，则返回 true
        var foundOnAnyPeer = false
        var lastError: Error?
        
        for (index, peer) in peers.enumerated() {
            let peerIDShort = peer.b58String.prefix(12)
            print("[SyncManager]   检查对等点 [\(index + 1)/\(peers.count)]: \(peerIDShort)...")
            
            do {
                // 尝试获取该 syncID 的 MST 根，如果成功则说明对等点有该文件夹
                // 增加超时时间和重试次数，因为首次连接可能需要时间
                let response: SyncResponse = try await app.requestSync(
                    .getMST(syncID: syncID),
                    to: peer,
                    timeout: 30.0,  // 增加到 30 秒
                    maxRetries: 2    // 增加到 2 次重试
                )
                
                // 如果返回的不是错误，说明对等点有该 syncID
                if case .mstRoot = response {
                    print("[SyncManager] ✅ 在对等点 \(peerIDShort)... 找到 syncID: \(syncID)")
                    foundOnAnyPeer = true
                    break // 找到一个就足够了
                } else {
                    print("[SyncManager] ⚠️ 对等点 \(peerIDShort)... 返回了意外的响应类型")
                }
            } catch {
                // 记录错误，但继续检查下一个对等点
                lastError = error
                let errorString = String(describing: error)
                print("[SyncManager] ⚠️ 对等点 \(peerIDShort)... 查询失败: \(errorString)")
                
                // 如果是 "Folder not found"，说明对等点没有该 syncID，继续检查下一个
                // 如果是连接错误，也继续检查下一个对等点
                continue
            }
        }
        
        // 如果所有对等点都没有该 syncID，返回 false
        if !foundOnAnyPeer {
            print("[SyncManager] ❌ 未在已知对等点找到 syncID: \(syncID)")
            if let error = lastError {
                print("[SyncManager]   最后错误: \(error.localizedDescription)")
            }
            print("[SyncManager] 💡 可能的原因:")
            print("[SyncManager]   1. 对等点还没有配置该 syncID")
            print("[SyncManager]   2. 网络连接问题")
            print("[SyncManager]   3. 设备还没有完全发现对方")
            print("[SyncManager] 💡 建议: 如果确定 syncID 正确，可以尝试直接加入（系统会自动同步）")
            return false
        }
        
        return true
    }
    
    /// 获取总设备数量（包括自身）
    public var totalDeviceCount: Int {
        peers.count + 1 // 包括自身
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
        
        // 添加其他设备（使用实际在线状态）
        for peer in peers {
            let peerIDString = peer.b58String
            let isOnline = peerOnlineStatus[peerIDString] ?? true // 默认为在线（新发现的设备）
            devices.append(DeviceInfo(
                peerID: peerIDString,
                isLocal: false,
                status: isOnline ? "在线" : "离线"
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

