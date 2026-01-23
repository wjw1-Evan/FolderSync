import SwiftUI
import ServiceManagement

@main
struct FolderSyncApp: App {
    @StateObject private var syncManager = SyncManager()
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    
    @Environment(\.openWindow) private var openWindow
    
    init() {
        checkSingleInstance()
    }
    
    private func checkSingleInstance() {
        let currentApp = NSRunningApplication.current
        let runningApps = NSWorkspace.shared.runningApplications
        
        // Get the name of this executable
        let executableName = Bundle.main.executableURL?.lastPathComponent ?? "FolderSync"
        
        let otherInstances = runningApps.filter { app in
            // Try to match by bundle identifier first
            if let bundleID = Bundle.main.bundleIdentifier, 
               bundleID != "com.apple.dt.Xcode",
               app.bundleIdentifier == bundleID {
                return app.processIdentifier != currentApp.processIdentifier
            }
            
            // Fallback to name check (localizedName or executable name)
            let isSameName = app.localizedName == executableName || app.localizedName == "FolderSync"
            return isSameName && app.processIdentifier != currentApp.processIdentifier
        }
        
        if let otherInstance = otherInstances.first {
            print("Detected another instance of FolderSync (PID: \(otherInstance.processIdentifier)).")
            otherInstance.activate(options: .activateIgnoringOtherApps)
            exit(0)
        }
    }
    
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


