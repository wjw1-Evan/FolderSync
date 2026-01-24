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
                    if !self.peers.contains(where: { $0.b58String == peer.b58String }) {
                        let pid = peer.b58String
                        print("SyncManager: New peer discovered - \(pid)")
                        self.peers.append(peer)
                        for folder in self.folders {
                            self.syncWithPeer(peer: peer, folder: folder)
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
        }
    }
    
    /// 刷新文件夹的文件数量和文件夹数量统计（不触发同步）
    private func refreshFileCount(for folder: SyncFolder) {
        Task {
            let (_, metadata, folderCount) = await calculateFullState(for: folder)
            await MainActor.run {
                if let index = self.folders.firstIndex(where: { $0.id == folder.id }) {
                    self.folders[index].fileCount = metadata.count
                    self.folders[index].folderCount = folderCount
                }
            }
        }
    }
    
    func addFolder(_ folder: SyncFolder) {
        folders.append(folder)
        do {
            try StorageManager.shared.saveFolder(folder)
        } catch {
            print("[SyncManager] ❌ 无法保存文件夹配置: \(error)")
            print("[SyncManager] 错误详情: \(error.localizedDescription)")
        }
        startMonitoring(folder)
        
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
            
            // Try to sync with existing peers
            for peer in peers {
                syncWithPeer(peer: peer, folder: folder)
            }
        }
        
        // If it's a join, trigger an immediate sync
        triggerSync(for: folder)
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
                        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: fileURL)
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
                print("[SyncManager] 开始同步: folder=\(folder.syncID), peer=\(peerID.prefix(8))")
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .syncing, message: "Connecting to \(peerID.prefix(8))...")
                }
                
                // 1. Get remote MST root
                let rootRes: SyncResponse
                do {
                    rootRes = try await app.requestSync(.getMST(syncID: folder.syncID), to: peer)
                } catch {
                    print("[SyncManager] ❌ 获取远程 MST 根失败: \(error)")
                    print("[SyncManager] 错误详情: \(error.localizedDescription)")
                    throw error
                }
                
                if case .error = rootRes {
                    removeFolderPeer(folder.syncID, peerID: peerID)
                    return
                }
                
                // Peer confirmed to have this folder
                addFolderPeer(folder.syncID, peerID: peerID)
                
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
                let filesRes: SyncResponse = try await app.requestSync(.getFiles(syncID: folder.syncID), to: peer)
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
                    let delRes: SyncResponse = try await app.requestSync(.deleteFiles(syncID: folder.syncID, paths: Array(toDelete)), to: peer)
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
                
                for (path, remoteMeta) in changedFiles {
                    let fileName = URL(fileURLWithPath: path).lastPathComponent
                    await MainActor.run {
                        self.updateFolderStatus(folder.id, status: .syncing, message: "Downloading \(fileName)", progress: totalOps > 0 ? Double(completedOps) / Double(totalOps) : 1.0)
                    }
                    let dataRes: SyncResponse = try await app.requestSync(.getFileData(syncID: folder.syncID, path: path), to: peer)
                    if case .fileData(_, _, let data) = dataRes {
                        let localURL = folder.localPath.appendingPathComponent(path)
                        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: localURL)
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
                    let dataRes: SyncResponse = try await app.requestSync(.getFileData(syncID: folder.syncID, path: path), to: peer)
                    if case .fileData(_, _, let data) = dataRes {
                        let pathDir = (path as NSString).deletingLastPathComponent
                        let parent = pathDir.isEmpty ? folder.localPath : folder.localPath.appendingPathComponent(pathDir)
                        let base = (fileName as NSString).deletingPathExtension
                        let ext = (fileName as NSString).pathExtension
                        let suffix = ext.isEmpty ? "" : ".\(ext)"
                        let conflictName = "\(base).conflict.\(String(peerID.prefix(8))).\(Int(remoteMeta.mtime.timeIntervalSince1970))\(suffix)"
                        let conflictURL = parent.appendingPathComponent(conflictName)
                        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                        try data.write(to: conflictURL)
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
                    let data = try Data(contentsOf: fileURL)
                    let putRes: SyncResponse = try await app.requestSync(.putFileData(syncID: folder.syncID, path: path, data: data, vectorClock: vc), to: peer)
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
                
                removeFolderPeer(folder.syncID, peerID: peerID)
                await MainActor.run {
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
                    // 处理文件
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
                }
            } catch {
                print("Error processing file \(fileURL): \(error)")
            }
        }
        return (mst, metadata, folderCount)
    }
    
    func checkIfSyncIDExists(_ syncID: String) async -> Bool {
        // In a real P2P app, we would query the DHT for this syncID
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        if folders.contains(where: { $0.syncID == syncID }) {
            return true
        }
        
        return syncID.count >= 4
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
        
        // 添加其他设备
        for peer in peers {
            devices.append(DeviceInfo(
                peerID: peer.b58String,
                isLocal: false,
                status: "在线"
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

