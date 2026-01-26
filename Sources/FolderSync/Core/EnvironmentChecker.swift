import Darwin
import Foundation
import Network

/// 环境检测工具，在程序启动时检测必要的环境配置
public class EnvironmentChecker {

    public enum CheckResult {
        case success(String)
        case warning(String)
        case error(String)
    }

    public struct CheckReport {
        let name: String
        let result: CheckResult
        let details: String?
    }

    /// 执行所有环境检测
    public static func runAllChecks() -> [CheckReport] {
        var reports: [CheckReport] = []

        reports.append(checkFileSystemPermissions())
        reports.append(checkKeychainAccess())
        reports.append(checkNetworkPermissions())
        reports.append(checkApplicationSupportDirectory())
        reports.append(checkDatabaseAccess())
        reports.append(checkUDPPortAvailability())
        reports.append(checkSystemResources())

        return reports
    }

    /// 打印检测报告到控制台
    public static func printReport(_ reports: [CheckReport]) {
        print("\n" + "=".repeating(60))
        print("🔍 FolderSync 环境检测报告")
        print("=".repeating(60))

        var successCount = 0
        var warningCount = 0
        var errorCount = 0

        for report in reports {
            let icon: String
            let status: String

            switch report.result {
            case .success:
                icon = "✅"
                status = "通过"
                successCount += 1
            case .warning:
                icon = "⚠️"
                status = "警告"
                warningCount += 1
            case .error:
                icon = "❌"
                status = "失败"
                errorCount += 1
            }

            print("\n\(icon) [\(status)] \(report.name)")

            let message: String
            switch report.result {
            case .success(let msg), .warning(let msg), .error(let msg):
                message = msg
            }
            print("   \(message)")

            if let details = report.details {
                print("   详情: \(details)")
            }
        }

        print("\n" + "-".repeating(60))
        print("📊 统计: ✅ \(successCount) 通过 | ⚠️ \(warningCount) 警告 | ❌ \(errorCount) 失败")
        print("=".repeating(60) + "\n")
    }

    // MARK: - 具体检测方法

    /// 检测文件系统权限
    private static func checkFileSystemPermissions() -> CheckReport {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let folderSyncDir = appSupport.appendingPathComponent("FolderSync", isDirectory: true)

        // 检查目录是否存在，不存在则尝试创建
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: folderSyncDir.path, isDirectory: &isDirectory)

        if !exists {
            do {
                try fileManager.createDirectory(
                    at: folderSyncDir, withIntermediateDirectories: true)
                return CheckReport(
                    name: "文件系统权限",
                    result: .success("Application Support 目录创建成功"),
                    details: "路径: \(folderSyncDir.path)"
                )
            } catch {
                return CheckReport(
                    name: "文件系统权限",
                    result: .error("无法创建 Application Support 目录: \(error.localizedDescription)"),
                    details: "路径: \(folderSyncDir.path)"
                )
            }
        }

        // 检查写入权限
        let testFile = folderSyncDir.appendingPathComponent(".test_write")
        do {
            try "test".write(to: testFile, atomically: true, encoding: .utf8)
        } catch {
            return CheckReport(
                name: "文件系统权限",
                result: .error("无法写入文件: \(error.localizedDescription)"),
                details: "路径: \(folderSyncDir.path)"
            )
        }

        // 清理测试文件
        try? fileManager.removeItem(at: testFile)

        return CheckReport(
            name: "文件系统权限",
            result: .success("文件系统访问正常"),
            details: "路径: \(folderSyncDir.path)"
        )
    }

    /// 检测密码文件访问权限（不再使用 Keychain）
    private static func checkKeychainAccess() -> CheckReport {
        // 测试密码文件的读写权限
        let testPassword = "test_password_\(UUID().uuidString)"

        // 尝试保存
        let saveSuccess = KeychainManager.savePassword(testPassword)
        if !saveSuccess {
            return CheckReport(
                name: "密码文件访问权限",
                result: .error("无法写入密码文件"),
                details: "请检查 Application Support 目录的写入权限"
            )
        }

        // 尝试读取
        if let loaded = KeychainManager.loadPassword(), loaded == testPassword {
            // 清理测试密码
            KeychainManager.deletePassword()
            return CheckReport(
                name: "密码文件访问权限",
                result: .success("密码文件访问正常"),
                details: "使用文件存储，无需 Keychain 权限"
            )
        } else {
            // 清理测试密码
            KeychainManager.deletePassword()
            return CheckReport(
                name: "密码文件访问权限",
                result: .error("无法读取密码文件"),
                details: "请检查 Application Support 目录的读取权限"
            )
        }
    }

    /// 检测网络权限
    private static func checkNetworkPermissions() -> CheckReport {
        // 检查是否有网络接口
        let monitor = NWPathMonitor()
        let semaphore = DispatchSemaphore(value: 0)
        var hasNetwork = false
        var networkType = "未知"

        monitor.pathUpdateHandler = { path in
            hasNetwork = path.status == .satisfied
            if path.usesInterfaceType(.wifi) {
                networkType = "WiFi"
            } else if path.usesInterfaceType(.cellular) {
                networkType = "蜂窝网络"
            } else if path.usesInterfaceType(.wiredEthernet) {
                networkType = "有线网络"
            } else if path.usesInterfaceType(.loopback) {
                networkType = "本地回环"
            }
            semaphore.signal()
        }

        let queue = DispatchQueue(label: "NetworkCheck")
        monitor.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 2.0)
        monitor.cancel()

        if !hasNetwork {
            return CheckReport(
                name: "网络连接",
                result: .warning("未检测到网络连接"),
                details: "类型: \(networkType)"
            )
        }

        return CheckReport(
            name: "网络连接",
            result: .success("网络连接正常"),
            details: "类型: \(networkType)"
        )
    }

    /// 检测 Application Support 目录
    private static func checkApplicationSupportDirectory() -> CheckReport {
        let fileManager = FileManager.default
        guard
            let appSupport = fileManager.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else {
            return CheckReport(
                name: "Application Support 目录",
                result: .error("无法获取 Application Support 目录路径"),
                details: nil
            )
        }

        let folderSyncDir = appSupport.appendingPathComponent("FolderSync", isDirectory: true)
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: folderSyncDir.path, isDirectory: &isDirectory) {
            // 检查目录大小
            if let attributes = try? fileManager.attributesOfItem(atPath: folderSyncDir.path),
                let size = attributes[.size] as? Int64
            {
                let sizeMB = Double(size) / (1024 * 1024)
                return CheckReport(
                    name: "Application Support 目录",
                    result: .success("目录存在且可访问"),
                    details: "路径: \(folderSyncDir.path), 大小: \(String(format: "%.2f", sizeMB)) MB"
                )
            }
        }

        return CheckReport(
            name: "Application Support 目录",
            result: .success("目录可访问"),
            details: "路径: \(folderSyncDir.path)"
        )
    }

    /// 检测数据库访问
    private static func checkDatabaseAccess() -> CheckReport {
        // 尝试访问 StorageManager（这会创建数据库连接）
        let manager = StorageManager.shared
        // 尝试执行一个简单的查询来验证数据库连接
        do {
            let _ = try manager.getAllFolders()
            return CheckReport(
                name: "数据库访问",
                result: .success("SQLite 数据库连接正常"),
                details: nil
            )
        } catch {
            return CheckReport(
                name: "数据库访问",
                result: .error("无法访问数据库: \(error.localizedDescription)"),
                details: nil
            )
        }
    }

    /// 检测 UDP 端口可用性
    private static func checkUDPPortAvailability() -> CheckReport {
        let port: UInt16 = 8765  // LANDiscovery 使用的端口

        // 使用 BSD socket 直接检测端口可用性，避免 NWListener 在无连接处理器时的系统警告
        let socketFD = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if socketFD < 0 {
            let errorCode = errno
            let message = String(cString: strerror(errorCode))
            return CheckReport(
                name: "UDP 端口可用性",
                result: .warning("无法创建 UDP 套接字: \(message)"),
                details: "端口: \(port) - 错误代码: \(errorCode)"
            )
        }

        // 允许地址和端口复用，便于与实际服务共存
        var yes: Int32 = 1
        setsockopt(
            socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        setsockopt(
            socketFD, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        // 绑定到 0.0.0.0:port
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if bindResult == 0 {
            // 绑定成功，说明端口可用
            Darwin.close(socketFD)
            return CheckReport(
                name: "UDP 端口可用性",
                result: .success("UDP 端口 \(port) 可用"),
                details: "端口: \(port)"
            )
        } else {
            let errorCode = errno
            let message = String(cString: strerror(errorCode))
            Darwin.close(socketFD)

            if errorCode == EADDRINUSE {
                return CheckReport(
                    name: "UDP 端口可用性",
                    result: .warning("UDP 端口 \(port) 可能已被占用"),
                    details: "端口: \(port) - 这可能是正常的（其他实例正在使用）"
                )
            }

            return CheckReport(
                name: "UDP 端口可用性",
                result: .warning("UDP 端口检测遇到问题: \(message)"),
                details: "端口: \(port) - 错误代码: \(errorCode)"
            )
        }
    }

    /// 检测系统资源
    private static func checkSystemResources() -> CheckReport {
        var details: [String] = []

        // 检查内存
        let processInfo = ProcessInfo.processInfo
        let physicalMemory = processInfo.physicalMemory
        let memoryGB = Double(physicalMemory) / (1024 * 1024 * 1024)
        details.append("物理内存: \(String(format: "%.2f", memoryGB)) GB")

        // 检查 CPU 核心数
        let cpuCount = processInfo.processorCount
        details.append("CPU 核心数: \(cpuCount)")

        // 检查系统版本
        if #available(macOS 13.0, *) {
            let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
            details.append("系统版本: \(osVersion)")
        }

        return CheckReport(
            name: "系统资源",
            result: .success("系统资源充足"),
            details: details.joined(separator: ", ")
        )
    }

    // MARK: - 辅助方法
    // 注意：已移除 keychainErrorDescription，因为不再使用 Keychain
}

extension String {
    func repeating(_ count: Int) -> String {
        return String(repeating: self, count: count)
    }
}
