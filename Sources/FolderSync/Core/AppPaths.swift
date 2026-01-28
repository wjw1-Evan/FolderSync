import Foundation

/// FolderSync 运行时路径集中管理。
///
/// 目标：
/// - 生产环境：使用 `~/Library/Application Support/FolderSync`
/// - 测试环境：默认使用临时目录，避免污染用户真实数据、避免跨测试互相影响
/// - 支持通过环境变量覆盖（便于调试/集成测试）
public enum AppPaths {
    /// 通过环境变量强制指定 FolderSync 的数据目录（最终目录，不再追加 "FolderSync"）
    ///
    /// 例：`FOLDERSYNC_APP_DIR=/tmp/FolderSyncSandbox`
    private static let overrideEnvKey = "FOLDERSYNC_APP_DIR"

    /// 是否在 XCTest 环境中运行
    public static var isRunningTests: Bool {
        // XCTest 在运行时会注入该环境变量；同时做一个类存在性兜底
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }

    /// FolderSync 数据目录（确保存在）
    ///
    /// - 生产：`~/Library/Application Support/FolderSync`
    /// - 测试：`$TMPDIR/FolderSyncTests-<pid>`
    public static var appDirectory: URL {
        let fm = FileManager.default

        if let override = ProcessInfo.processInfo.environment[overrideEnvKey], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        if isRunningTests {
            let pid = ProcessInfo.processInfo.processIdentifier
            let url = fm.temporaryDirectory.appendingPathComponent("FolderSyncTests-\(pid)", isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        // 默认：Application Support/FolderSync
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupport.appendingPathComponent("FolderSync", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

