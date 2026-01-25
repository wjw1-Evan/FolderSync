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
        
        // 同步系统登录项状态到 UI
        syncLaunchAtLoginStatus()
    }
    
    /// 同步系统登录项状态到 UI
    private func syncLaunchAtLoginStatus() {
        let service = SMAppService.mainApp
        let systemStatus = service.status
        
        // 根据系统状态更新 UI 状态
        let shouldBeEnabled: Bool
        switch systemStatus {
        case .enabled:
            shouldBeEnabled = true
            print("[FolderSyncApp] ✅ 系统登录项状态：已启用")
        case .requiresApproval:
            // requiresApproval 表示已注册但需要用户批准，应该显示为启用状态
            shouldBeEnabled = true
            print("[FolderSyncApp] ⚠️ 系统登录项状态：已注册，需要用户批准（请在系统设置中允许）")
        case .notRegistered, .notFound:
            shouldBeEnabled = false
            print("[FolderSyncApp] ℹ️ 系统登录项状态：未注册")
        @unknown default:
            shouldBeEnabled = false
            print("[FolderSyncApp] ⚠️ 系统登录项状态：未知状态")
        }
        
        // 只在状态不同时更新，避免不必要的 UI 刷新
        if launchAtLogin != shouldBeEnabled {
            launchAtLogin = shouldBeEnabled
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
                .onAppear {
                    // 每次菜单显示时同步系统状态
                    syncLaunchAtLoginStatus()
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
                print("[FolderSyncApp] ✅ 已注册开机自动启动")
            } else {
                try service.unregister()
                print("[FolderSyncApp] ✅ 已取消开机自动启动")
            }
            
            // 操作后立即同步状态，确保 UI 与系统状态一致
            // 延迟一小段时间，让系统状态更新完成
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.syncLaunchAtLoginStatus()
            }
        } catch {
            print("[FolderSyncApp] ❌ 设置开机自动启动失败: \(error)")
            print("[FolderSyncApp] 错误详情: \(error.localizedDescription)")
            
            // 如果操作失败，恢复 UI 状态到系统实际状态
            syncLaunchAtLoginStatus()
        }
    }
}


