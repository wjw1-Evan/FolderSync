import SwiftUI
import ServiceManagement

@main
struct FolderSyncApp: App {
    @StateObject private var syncManager = SyncManager()
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    
    @Environment(\.openWindow) private var openWindow
    
    init() {
        // Enforce Single Instance
        let bundleID = Bundle.main.bundleIdentifier ?? "com.FolderSync.App"
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        
        let currentApp = NSRunningApplication.current
        
        for app in runningApps {
            if app != currentApp {
                // Already running
                print("App is already running. activating existing instance.")
                app.activate()
                
                // Terminate current instance
                // We can't use NSApplication.shared.terminate here as it might not be ready,
                // so we use exit(0)
                exit(0)
            }
        }
    }
    
    var body: some Scene {
        WindowGroup(id: "main") {
            MainDashboard()
                .environmentObject(syncManager)
        }
        .defaultSize(width: 800, height: 600)
        .windowStyle(.automatic)
        .commands {
            // 移除默认的"新建窗口"菜单项，防止用户通过菜单创建多个窗口
            CommandGroup(replacing: .newItem) {}
        }
        
        MenuBarExtra("FolderSync", systemImage: "arrow.triangle.2.circlepath") {
            Button("显示主界面") {
                // 检查是否已经有主窗口打开
                // 查找所有可见的窗口，优先检查标识符，其次检查标题
                let existingWindow = NSApplication.shared.windows.first { window in
                    window.isVisible && (
                        window.identifier?.rawValue == "main" ||
                        window.title == "FolderSync 仪表盘"
                    )
                }
                
                if let window = existingWindow {
                    // 如果窗口已存在，激活它并带到前台
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    // 如果窗口不存在，打开新窗口
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
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


