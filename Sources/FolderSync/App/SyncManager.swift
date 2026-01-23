import SwiftUI
import Combine
import Crypto
import LibP2P
import LibP2PCore

public class SyncManager: ObservableObject {
    @Published var folders: [SyncFolder] = []
    @Published var peers: [String] = [] // PeerIDs
    @Published var folderPeers: [String: Set<String>] = [:] // SyncID -> PeerIDs
    let p2pNode = P2PNode()
    
    private var monitors: [UUID: FSEventsMonitor] = [:]
    
    public init() {
        // Load from storage
        self.folders = (try? StorageManager.shared.getAllFolders()) ?? []
        
        Task {
            p2pNode.onPeerDiscovered = { [weak self] peerID in
                DispatchQueue.main.async {
                    if self?.peers.contains(peerID) == false {
                        self?.peers.append(peerID)
                        // Trigger sync when peer is found
                        for folder in self?.folders ?? [] {
                            self?.syncWithPeer(peerID: peerID, folder: folder)
                        }
                    }
                }
            }
            
            try? await p2pNode.start()
            
            // Register P2P handlers
            setupP2PHandlers()
            
            // Start monitoring and announcing all folders
            await MainActor.run {
                for folder in folders {
                    startMonitoring(folder)
                }
            }
        }
    }
    
    func addFolder(_ folder: SyncFolder) {
        folders.append(folder)
        try? StorageManager.shared.saveFolder(folder)
        startMonitoring(folder)
        
        // Announce this folder on the network
        Task {
            try? await p2pNode.announce(service: "folder-sync-\(folder.syncID)")
            
            // Try to sync with existing peers
            for peer in peers {
                syncWithPeer(peerID: peer, folder: folder)
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
                    self?.syncWithPeer(peerID: peer, folder: folder)
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
    
    private func isIgnored(_ path: String) -> Bool {
        for pattern in ignorePatterns {
            if pattern.hasSuffix("/") {
                if path.contains(pattern) || path.hasPrefix(pattern.replacingOccurrences(of: "/", with: "")) {
                    return true
                }
            } else if path.hasSuffix(pattern) {
                return true
            }
        }
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
                    if let folder = self.folders.first(where: { $0.syncID == syncID }) {
                        let (mst, _) = await self.calculateFullState(for: folder.localPath)
                        return .mstRoot(syncID: syncID, rootHash: mst.rootHash ?? "empty")
                    }
                    return .error("Folder not found")
                    
                case .getFiles(let syncID):
                    if let folder = self.folders.first(where: { $0.syncID == syncID }) {
                        let (_, metadata) = await self.calculateFullState(for: folder.localPath)
                        return .files(syncID: syncID, entries: metadata)
                    }
                    return .error("Folder not found")
                    
                case .getFileData(let syncID, let relativePath):
                    if let folder = self.folders.first(where: { $0.syncID == syncID }) {
                        let fileURL = folder.localPath.appendingPathComponent(relativePath)
                        let data = try Data(contentsOf: fileURL)
                        return .fileData(syncID: syncID, path: relativePath, data: data)
                    }
                    return .error("Folder not found")
                }
            } catch {
                return .error(error.localizedDescription)
            }
        }
    }
    
    private func syncWithPeer(peerID: String, folder: SyncFolder) {
        guard let app = p2pNode.app, let peer = try? PeerID(cid: peerID) else { return }
        
        Task {
            do {
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .syncing, message: "Connecting to \(peerID.prefix(8))...")
                }
                
                // 1. Get remote MST root
                let rootRes: SyncResponse = try await app.requestSync(.getMST(syncID: folder.syncID), to: peer)
                
                if case .error = rootRes {
                    await removeFolderPeer(folder.syncID, peerID: peerID)
                    return
                }
                
                // Peer confirmed to have this folder
                await addFolderPeer(folder.syncID, peerID: peerID)
                
                guard case .mstRoot(_, let remoteHash) = rootRes else { return }
                
                let (localMST, localMetadata) = await calculateFullState(for: folder.localPath)
                if localMST.rootHash == remoteHash {
                    await MainActor.run {
                        self.updateFolderStatus(folder.id, status: .synced, message: "Up to date", progress: 1.0)
                    }
                    return
                }
                
                // 2. Roots differ, get remote file list
                let filesRes: SyncResponse = try await app.requestSync(.getFiles(syncID: folder.syncID), to: peer)
                guard case .files(_, let remoteEntries) = filesRes else { return }
                
                // 3. Find missing or changed files
                var changedFiles: [(String, FileMetadata)] = []
                for (path, remoteMeta) in remoteEntries {
                    if let localMeta = localMetadata[path] {
                        if localMeta.hash != remoteMeta.hash {
                            // Conflict Resolution: LWW (Last Writer Wins)
                            if remoteMeta.mtime > localMeta.mtime {
                                changedFiles.append((path, remoteMeta))
                            } else {
                                print("Local version is newer for \(path), skipping download.")
                            }
                        }
                    } else {
                        // File missing locally
                        changedFiles.append((path, remoteMeta))
                    }
                }
                
                if changedFiles.isEmpty {
                    await MainActor.run {
                        self.updateFolderStatus(folder.id, status: .synced, message: "No changes to download", progress: 1.0)
                    }
                    return
                }
                
                // 4. Download changed files
                let total = Double(changedFiles.count)
                for (index, (path, _)) in changedFiles.enumerated() {
                    let progress = Double(index) / total
                    let fileName = URL(fileURLWithPath: path).lastPathComponent
                    await MainActor.run {
                        self.updateFolderStatus(folder.id, status: .syncing, message: "Downloading \(fileName)", progress: progress)
                    }
                    
                    let dataRes: SyncResponse = try await app.requestSync(.getFileData(syncID: folder.syncID, path: path), to: peer)
                    if case .fileData(_, _, let data) = dataRes {
                        let localURL = folder.localPath.appendingPathComponent(path)
                        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: localURL)
                    }
                }
                
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .synced, message: "Sync complete", progress: 1.0)
                }
            } catch {
                await removeFolderPeer(folder.syncID, peerID: peerID)
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .error, message: error.localizedDescription)
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
            let (mst, _) = await calculateFullState(for: folder.localPath)
            print("Folder \(folder.localPath.lastPathComponent) hash: \(mst.rootHash ?? "empty")")
            
            // 2. Try sync with all peers
            if peers.isEmpty {
                await MainActor.run {
                    self.updateFolderStatus(folder.id, status: .synced, message: "No peers found", progress: 0.0)
                }
            } else {
                for peer in peers {
                    syncWithPeer(peerID: peer, folder: folder)
                }
            }
        }
    }
    
    private func calculateFullState(for url: URL) async -> (MerkleSearchTree, [String: FileMetadata]) {
        let mst = MerkleSearchTree()
        var metadata: [String: FileMetadata] = [:]
        let fileManager = FileManager.default
        
        let resourceKeys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .contentModificationDateKey]
        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles])
        
        while let fileURL = enumerator?.nextObject() as? URL {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                if resourceValues.isDirectory == false {
                    var relativePath = fileURL.path.replacingOccurrences(of: url.path, with: "")
                    if relativePath.hasPrefix("/") { relativePath.removeFirst() }
                    
                    // Filter ignored files
                    if isIgnored(relativePath) { continue }
                    
                    let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                    let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
                    let mtime = resourceValues.contentModificationDate ?? Date()
                    
                    mst.insert(key: relativePath, value: hash)
                    metadata[relativePath] = FileMetadata(hash: hash, mtime: mtime)
                }
            } catch {
                print("Error processing file \(fileURL): \(error)")
            }
        }
        return (mst, metadata)
    }
    
    func checkIfSyncIDExists(_ syncID: String) async -> Bool {
        // In a real P2P app, we would query the DHT for this syncID
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        if folders.contains(where: { $0.syncID == syncID }) {
            return true
        }
        
        return syncID.count >= 4
    }
}

