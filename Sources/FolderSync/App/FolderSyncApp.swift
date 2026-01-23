import SwiftUI
import ServiceManagement

@main
struct FolderSyncApp: App {
    @StateObject private var syncManager = SyncManager()
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    
    @Environment(\.openWindow) private var openWindow
    
    var body: some Scene {
        WindowGroup(id: "main") {
            MainDashboard()
                .environmentObject(syncManager)
        }
        
        MenuBarExtra("FolderSync", systemImage: "arrow.triangle.2.circlepath") {
            Button("显示主界面") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Toggle("开机自动启动", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { newValue in
                    toggleLaunchAtLogin(newValue)
                }
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
    
    private func toggleLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            print("Failed to set launch at login: \(error)")
        }
    }
}

class SyncManager: ObservableObject {
    @Published var folders: [SyncFolder] = []
    @Published var peers: [String] = [] // PeerIDs
    let p2pNode = P2PNode()
    
    init() {
        // Load from storage
        self.folders = (try? StorageManager.shared.getAllFolders()) ?? []
        
        Task {
            try? await p2pNode.start()
        }
    }
}
