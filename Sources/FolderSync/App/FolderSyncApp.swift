import SwiftUI
import ServiceManagement
import AppKit
import os.log

// AppDelegate 用于处理应用退出
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 关闭所有打开的窗口和 sheet
        for window in NSApplication.shared.windows {
            // 关闭所有 sheet（sheet 窗口的 sheetParent 不为 nil）
            if window.sheetParent != nil {
                window.sheetParent?.endSheet(window)
            } else {
                // 关闭普通窗口
                window.close()
            }
        }
        // 允许退出
        return .terminateNow
    }
}

@main
struct FolderSyncApp: App {
    @StateObject private var syncManager = SyncManager()
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    
    @Environment(\.openWindow) private var openWindow
    
    // 日志系统
    private static let logger = Logger(subsystem: "com.FolderSync.App", category: "App")
    
    // AppDelegate 实例
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        // 设置应用为 GUI 模式，不显示终端窗口
        NSApplication.shared.setActivationPolicy(.regular)
        
        // 重定向标准输出和错误输出到日志文件（可选，用于调试）
        setupLogging()
        
        // Enforce Single Instance
        let bundleID = Bundle.main.bundleIdentifier ?? "com.FolderSync.App"
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        
        let currentApp = NSRunningApplication.current
        
        for app in runningApps {
            if app != currentApp {
                // Already running
                Self.logger.info("应用已在运行，激活现有实例")
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
    
    /// 设置日志系统，将控制台输出重定向到日志文件
    private func setupLogging() {
        // 获取日志文件路径
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folderSyncDir = appSupport.appendingPathComponent("FolderSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderSyncDir, withIntermediateDirectories: true)
        
        let logFile = folderSyncDir.appendingPathComponent("app.log")
        
        // 创建文件句柄用于写入日志
        if let fileHandle = try? FileHandle(forWritingTo: logFile) {
            fileHandle.seekToEndOfFile()
            
            // 注意：在 macOS 上，直接重定向 stdout/stderr 可能会影响 SwiftUI
            // 所以我们保留 print 但使用 os.log 作为主要日志系统
            // 如果需要，可以将 print 输出也写入文件
        }
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
            Self.logger.info("系统登录项状态：已启用")
        case .requiresApproval:
            // requiresApproval 表示已注册但需要用户批准，应该显示为启用状态
            shouldBeEnabled = true
            Self.logger.warning("系统登录项状态：已注册，需要用户批准（请在系统设置中允许）")
        case .notRegistered, .notFound:
            shouldBeEnabled = false
            Self.logger.info("系统登录项状态：未注册")
        @unknown default:
            shouldBeEnabled = false
            Self.logger.warning("系统登录项状态：未知状态")
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
            Button(LocalizedString.showMainWindow) {
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
            Toggle(LocalizedString.launchAtLogin, isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { oldValue, newValue in
                    toggleLaunchAtLogin(newValue)
                }
                .onAppear {
                    // 每次菜单显示时同步系统状态
                    syncLaunchAtLoginStatus()
                }
            Button(LocalizedString.quit) {
                quitApplication()
            }
        }
    }
    
    private func toggleLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
                Self.logger.info("已注册开机自动启动")
            } else {
                try service.unregister()
                Self.logger.info("已取消开机自动启动")
            }
            
            // 操作后立即同步状态，确保 UI 与系统状态一致
            // 延迟一小段时间，让系统状态更新完成
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.syncLaunchAtLoginStatus()
            }
        } catch {
            Self.logger.error("设置开机自动启动失败: \(error.localizedDescription)")
            
            // 如果操作失败，恢复 UI 状态到系统实际状态
            syncLaunchAtLoginStatus()
        }
    }
    
    /// 退出应用，先关闭所有打开的窗口和 sheet
    private func quitApplication() {
        // 关闭所有打开的窗口和 sheet
        let windows = NSApplication.shared.windows
        for window in windows {
            // 如果有 sheet 打开，先关闭 sheet
            if let parent = window.sheetParent {
                parent.endSheet(window)
            } else {
                // 关闭普通窗口
                window.close()
            }
        }
        
        // 延迟一小段时间确保窗口关闭，然后退出应用
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApplication.shared.terminate(nil)
        }
    }
}


