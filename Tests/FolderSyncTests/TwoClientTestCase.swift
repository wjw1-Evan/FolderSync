import Foundation
import XCTest

@testable import FolderSync

// MARK: - 测试用时间常量

/// 测试用等待时间常量（纳秒）
enum TestDuration {
    /// P2P 节点启动等待时间（2秒）
    static let p2pStartup: UInt64 = 2_000_000_000
    /// 文件夹发现等待时间（5秒）
    static let folderDiscovery: UInt64 = 5_000_000_000
    /// 短同步等待时间（3秒）
    static let shortSync: UInt64 = 3_000_000_000
    /// 中等同步等待时间（5秒）
    static let mediumSync: UInt64 = 5_000_000_000
    /// 长同步等待时间（10秒）
    static let longSync: UInt64 = 10_000_000_000
    /// 操作间隔（1秒）
    static let operationGap: UInt64 = 1_000_000_000
    /// 处理等待（2秒）
    static let processingWait: UInt64 = 2_000_000_000
    /// P2P 停止超时（5秒）
    static let p2pStopTimeout: UInt64 = 5_000_000_000
    /// 重连发现等待时间（3秒）
    static let reconnectDiscovery: UInt64 = 3_000_000_000
}

// MARK: - 双客户端测试基类

/// 双客户端同步测试基类
/// 封装两个 SyncManager 实例的公共 setUp/tearDown 逻辑
class TwoClientTestCase: XCTestCase {
    var tempDir1: URL!
    var tempDir2: URL!
    var syncManager1: SyncManager!
    var syncManager2: SyncManager!
    var syncID: String!

    /// 子类可重写以自定义文件夹发现等待时间
    var folderDiscoveryWait: UInt64 { TestDuration.folderDiscovery }

    @MainActor
    override func setUp() async throws {
        try await super.setUp()

        tempDir1 = try TestHelpers.createTempDirectory()
        tempDir2 = try TestHelpers.createTempDirectory()
        syncID = "test\(UUID().uuidString.prefix(8))"

        syncManager1 = SyncManager()
        syncManager2 = SyncManager()

        // 等待 P2P 节点启动
        try? await Task.sleep(nanoseconds: TestDuration.p2pStartup)

        // 添加文件夹
        let folder1 = TestHelpers.createTestSyncFolder(syncID: syncID, localPath: tempDir1)
        syncManager1.addFolder(folder1)

        let folder2 = TestHelpers.createTestSyncFolder(syncID: syncID, localPath: tempDir2)
        syncManager2.addFolder(folder2)

        // 等待文件夹添加和发现
        try? await Task.sleep(nanoseconds: folderDiscoveryWait)
    }

    @MainActor
    override func tearDown() async throws {
        // 使用带超时的安全停止方式
        await stopP2PNodeSafely(syncManager1)
        await stopP2PNodeSafely(syncManager2)

        syncManager1 = nil
        syncManager2 = nil

        if tempDir1 != nil { TestHelpers.cleanupTempDirectory(tempDir1) }
        if tempDir2 != nil { TestHelpers.cleanupTempDirectory(tempDir2) }

        try await super.tearDown()
    }

    // MARK: - 公共辅助方法

    /// 安全停止 P2P 节点（带超时保护，避免 hang）
    func stopP2PNodeSafely(
        _ syncManager: SyncManager?, timeout: UInt64 = TestDuration.p2pStopTimeout
    ) async {
        guard let sm = syncManager else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await sm.p2pNode.stop()
                // Sleep to allow callbacks to drain
                try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
            }
            group.addTask { try? await Task.sleep(nanoseconds: timeout) }
            for await _ in group {
                group.cancelAll()
                break
            }
        }
    }

    /// 模拟客户端2离线（停止其 P2P 网络服务）
    func simulateClient2Offline() async throws {
        try await syncManager2.p2pNode.stop()
    }

    /// 模拟客户端2上线（重新启动其 P2P 网络服务）
    func simulateClient2Online() async throws {
        try await syncManager2.p2pNode.start()
        try? await Task.sleep(nanoseconds: TestDuration.reconnectDiscovery)
    }

    /// 等待发现并从客户端1触发同步
    @MainActor
    func waitDiscoveryAndTriggerSyncFromClient1() async {
        try? await Task.sleep(nanoseconds: TestDuration.reconnectDiscovery)
        if let folder1 = syncManager1.folders.first(where: { $0.syncID == syncID }) {
            _ = await TestHelpers.triggerSyncAndWait(
                syncManager: syncManager1, folder: folder1, timeout: 25.0)
        }
    }
}
