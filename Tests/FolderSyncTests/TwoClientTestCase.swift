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

@MainActor
class TwoClientTestCase: XCTestCase {
    var tempDir1: URL!
    var tempDir2: URL!
    var syncManager1: SyncManager!
    var syncManager2: SyncManager!
    var syncID: String!

    /// 子类可重写以自定义文件夹发现等待时间
    var folderDiscoveryWait: UInt64 { TestDuration.folderDiscovery }

    override func setUp() async throws {
        try await super.setUp()

        tempDir1 = try TestHelpers.createTempDirectory()
        tempDir2 = try TestHelpers.createTempDirectory()
        syncID = "test\(UUID().uuidString.prefix(8))"

        syncManager1 = SyncManager()
        syncManager2 = SyncManager()

        // 等待 P2P 节点启动
        try? await Task.sleep(nanoseconds: TestDuration.p2pStartup)

        // 手动注册 peer（同一机器上 LAN Discovery 可能无法正常工作）
        if let p1 = syncManager1.p2pNode.peerID,
            let p2 = syncManager2.p2pNode.peerID,
            let port1 = syncManager1.p2pNode.signalingPort,
            let port2 = syncManager2.p2pNode.signalingPort
        {

            // 使用实际端口地址
            let addr1 = Multiaddr(string: "/ip4/127.0.0.1/tcp/\(port1)")!
            let addr2 = Multiaddr(string: "/ip4/127.0.0.1/tcp/\(port2)")!

            // 客户端2 注册 客户端1
            syncManager2.peerManager.addOrUpdatePeer(p1, addresses: [addr1])
            syncManager2.p2pNode.registrationService.registerPeer(peerID: p1, addresses: [addr1])
            syncManager2.peerManager.updateOnlineStatus(p1.b58String, isOnline: true)
            syncManager2.peerManager.updateSyncIDs(p1.b58String, syncIDs: [syncID!])

            // 客户端1 注册 客户端2
            syncManager1.peerManager.addOrUpdatePeer(p2, addresses: [addr2])
            syncManager1.p2pNode.registrationService.registerPeer(peerID: p2, addresses: [addr2])
            syncManager1.peerManager.updateOnlineStatus(p2.b58String, isOnline: true)
            syncManager1.peerManager.updateSyncIDs(p2.b58String, syncIDs: [syncID!])
        }

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

    // MARK: - 操作辅助方法

    /// 在指定目录创建文件并等待 (默认等待 6秒 以便 FSEvents 触发)
    func createFile(in dir: URL, name: String, content: String, wait: UInt64 = 6_000_000_000)
        async throws
    {
        let fileURL = dir.appendingPathComponent(name)
        try TestHelpers.createTestFile(at: fileURL, content: content)
        if wait > 0 {
            try await Task.sleep(nanoseconds: wait)
        }
    }

    /// 修改文件并等待
    func modifyFile(in dir: URL, name: String, content: String, wait: UInt64 = 6_000_000_000)
        async throws
    {
        try await createFile(in: dir, name: name, content: content, wait: wait)
    }

    /// 删除文件并等待
    func deleteFile(in dir: URL, name: String, wait: UInt64 = 3_000_000_000) async throws {
        let fileURL = dir.appendingPathComponent(name)
        if TestHelpers.directoryExists(at: fileURL) {
            try FileManager.default.removeItem(at: fileURL)
        } else if TestHelpers.fileExists(at: fileURL) {
            try FileManager.default.removeItem(at: fileURL)
        }
        if wait > 0 {
            try await Task.sleep(nanoseconds: wait)
        }
    }

    /// 重命名文件并等待
    func renameFile(in dir: URL, from: String, to: String, wait: UInt64 = 6_000_000_000)
        async throws
    {
        let fromURL = dir.appendingPathComponent(from)
        let toURL = dir.appendingPathComponent(to)
        try FileManager.default.moveItem(at: fromURL, to: toURL)
        if wait > 0 {
            try await Task.sleep(nanoseconds: wait)
        }
    }

    // MARK: - 断言辅助方法

    /// 断言文件存在
    func assertExists(
        in dir: URL, name: String, timeout: TimeInterval = 28.0, message: String? = nil
    ) async {
        let fileURL = dir.appendingPathComponent(name)
        let exists = await TestHelpers.waitForCondition(timeout: timeout) {
            TestHelpers.fileExists(at: fileURL)
        }
        XCTAssertTrue(exists, message ?? "文件 \(name) 应该在 \(dir.lastPathComponent) 中存在")
    }

    /// 断言目录存在
    func assertDirectoryExists(
        in dir: URL, name: String, timeout: TimeInterval = 28.0, message: String? = nil
    ) async {
        let folderURL = dir.appendingPathComponent(name)
        let exists = await TestHelpers.waitForCondition(timeout: timeout) {
            TestHelpers.directoryExists(at: folderURL)
        }
        XCTAssertTrue(exists, message ?? "目录 \(name) 应该在 \(dir.lastPathComponent) 中存在")
    }

    /// 断言文件或目录不存在
    func assertNotExists(
        in dir: URL, name: String, timeout: TimeInterval = 28.0, message: String? = nil
    ) async {
        let fileURL = dir.appendingPathComponent(name)
        let deleted = await TestHelpers.waitForCondition(timeout: timeout) {
            !TestHelpers.fileExists(at: fileURL) && !TestHelpers.directoryExists(at: fileURL)
        }
        XCTAssertTrue(deleted, message ?? "文件/目录 \(name) 应该已从 \(dir.lastPathComponent) 删除")
    }

    /// 断言文件内容
    func assertContent(in dir: URL, name: String, expected: String, timeout: TimeInterval = 28.0)
        async throws
    {
        let fileURL = dir.appendingPathComponent(name)
        let updated = await TestHelpers.waitForCondition(timeout: timeout) {
            guard let c = try? TestHelpers.readFileContent(at: fileURL) else { return false }
            return c == expected
        }
        XCTAssertTrue(updated, "文件 \(name) 内容应该同步为: \(expected)")
        if updated {
            let content = try TestHelpers.readFileContent(at: fileURL)
            XCTAssertEqual(content, expected)
        }
    }

    /// 获取目录中的冲突文件
    func getConflictFiles(in dir: URL, baseName: String? = nil) -> [URL] {
        let files = TestHelpers.getAllFiles(in: dir)
        return files.filter { url in
            let name = url.lastPathComponent
            let isConflict = name.contains(".conflict.")
            if let base = baseName {
                return isConflict && name.contains(base)
            }
            return isConflict
        }
    }
}
