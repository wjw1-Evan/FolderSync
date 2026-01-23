import SwiftUI
import Combine

public class SyncManager: ObservableObject {
    @Published var folders: [SyncFolder] = []
    @Published var peers: [String] = [] // PeerIDs
    let p2pNode = P2PNode()
    
    private var monitors: [UUID: FSEventsMonitor] = [:]
    
    public init() {
        // Load from storage
        self.folders = (try? StorageManager.shared.getAllFolders()) ?? []
        
        Task {
            try? await p2pNode.start()
            // Start monitoring all folders
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
        
        // If it's a join, trigger an immediate sync
        triggerSync(for: folder)
    }
    
    func removeFolder(_ folder: SyncFolder) {
        stopMonitoring(folder)
        folders.removeAll { $0.id == folder.id }
        try? StorageManager.shared.deleteFolder(folder.id)
    }
    
    private func startMonitoring(_ folder: SyncFolder) {
        let monitor = FSEventsMonitor(path: folder.localPath.path) { [weak self] path in
            print("File changed at: \(path)")
            self?.triggerSync(for: folder)
        }
        monitor.start()
        monitors[folder.id] = monitor
    }
    
    private func stopMonitoring(_ folder: SyncFolder) {
        monitors[folder.id]?.stop()
        monitors.removeValue(forKey: folder.id)
    }
    
    func triggerSync(for folder: SyncFolder) {
        // Update status to syncing
        if let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index].status = .syncing
            
            // Simulating sync work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                if let idx = self?.folders.firstIndex(where: { $0.id == folder.id }) {
                    self?.folders[idx].status = .synced
                }
            }
        }
    }
    
    func checkIfSyncIDExists(_ syncID: String) async -> Bool {
        // In a real app, this would query the P2P network.
        // For now, we'll simulate a check: maybe IDs starting with "invalid" don't exist.
        // Or if it's already in our local list, we say it exists.
        
        // Simulating network delay
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        if folders.contains(where: { $0.syncID == syncID }) {
            return true
        }
        
        // Dummy check: assume ID exists if it's longer than 3 characters
        return syncID.count >= 4
    }
}
