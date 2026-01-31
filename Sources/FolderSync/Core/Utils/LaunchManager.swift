import Foundation
import ServiceManagement
import os.log

/// 协议定义开机启动服务的功能，方便测试
public protocol LaunchServiceProtocol {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

/// 默认实现，使用 SMAppService.mainApp
extension SMAppService: LaunchServiceProtocol {}

/// 开机自动启动管理器
@MainActor
public class LaunchManager: ObservableObject {
    private static let logger = Logger(subsystem: "com.FolderSync.App", category: "LaunchManager")

    @Published public private(set) var isEnabled: Bool = false
    @Published public private(set) var requiresApproval: Bool = false

    private let service: LaunchServiceProtocol

    public init(service: LaunchServiceProtocol = SMAppService.mainApp) {
        self.service = service
        refreshStatus()
    }

    /// 刷新并同步系统实际状态
    public func refreshStatus() {
        let status = service.status

        switch status {
        case .enabled:
            isEnabled = true
            requiresApproval = false
        case .requiresApproval:
            isEnabled = true
            requiresApproval = true
            Self.logger.warning("开机启动项已注册，但需要用户在系统设置中批准")
        case .notRegistered, .notFound:
            isEnabled = false
            requiresApproval = false
        @unknown default:
            isEnabled = false
            requiresApproval = false
        }

        Self.logger.debug(
            "开机启动状态同步: isEnabled=\(self.isEnabled), requiresApproval=\(self.requiresApproval)")
    }

    /// 设置开机启动状态
    public func setEnabled(_ enabled: Bool) async throws {
        do {
            if enabled {
                try service.register()
                Self.logger.info("已向系统注册开机自动启动")
            } else {
                try service.unregister()
                Self.logger.info("已向系统取消开机自动启动")
            }

            // 稍作延迟等待系统处理
            try? await Task.sleep(nanoseconds: 100_000_000)
            refreshStatus()

        } catch {
            Self.logger.error("设置开机启动失败: \(error.localizedDescription)")
            refreshStatus()  // 恢复 UI 到实际状态
            throw error
        }
    }
}
