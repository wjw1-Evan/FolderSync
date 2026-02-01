import Foundation
import XCTest

@testable import FolderSync

// MARK: - 三客户端测试基类

/// 三客户端同步测试基类
/// 封装三个 SyncManager 实例的公共 setUp/tearDown 逻辑
@MainActor
class ThreeClientTestCase: XCTestCase {
    var tempDir1: URL!
    var tempDir2: URL!
    var tempDir3: URL!
    var syncManager1: SyncManager!
    var syncManager2: SyncManager!
    var syncManager3: SyncManager!
    var syncID: String!

    /// 子类可重写以自定义文件夹发现等待时间
    var folderDiscoveryWait: UInt64 { TestDuration.longSync }

    override func setUp() async throws {
        try await super.setUp()

        tempDir1 = try TestHelpers.createTempDirectory()
        tempDir2 = try TestHelpers.createTempDirectory()
        tempDir3 = try TestHelpers.createTempDirectory()
        syncID = "test\(UUID().uuidString.prefix(8))"

        syncManager1 = SyncManager()
        syncManager2 = SyncManager()
        syncManager3 = SyncManager()

        // 等待 P2P 节点启动
        try? await Task.sleep(nanoseconds: TestDuration.p2pStartup)

        // 手动注册 peer（同一机器上 LAN Discovery 可能无法正常工作）
        if let p1 = syncManager1.p2pNode.peerID,
            let p2 = syncManager2.p2pNode.peerID,
            let p3 = syncManager3.p2pNode.peerID
        {

            // 模拟地址
            let addr1 = Multiaddr(string: "/ip4/127.0.0.1/tcp/12345")!
            let addr2 = Multiaddr(string: "/ip4/127.0.0.1/tcp/12346")!
            let addr3 = Multiaddr(string: "/ip4/127.0.0.1/tcp/12347")!

            // 客户端2 和 3 注册 客户端1
            for manager in [syncManager2!, syncManager3!] {
                manager.peerManager.addOrUpdatePeer(p1, addresses: [addr1])
                manager.p2pNode.registrationService.registerPeer(peerID: p1, addresses: [addr1])
                manager.peerManager.updateOnlineStatus(p1.b58String, isOnline: true)
                manager.peerManager.updateSyncIDs(p1.b58String, syncIDs: [syncID!])
            }

            // 客户端1 和 3 注册 客户端2
            for manager in [syncManager1!, syncManager3!] {
                manager.peerManager.addOrUpdatePeer(p2, addresses: [addr2])
                manager.p2pNode.registrationService.registerPeer(peerID: p2, addresses: [addr2])
                manager.peerManager.updateOnlineStatus(p2.b58String, isOnline: true)
                manager.peerManager.updateSyncIDs(p2.b58String, syncIDs: [syncID!])
            }

            // 客户端1 和 2 注册 客户端3
            for manager in [syncManager1!, syncManager2!] {
                manager.peerManager.addOrUpdatePeer(p3, addresses: [addr3])
                manager.p2pNode.registrationService.registerPeer(peerID: p3, addresses: [addr3])
                manager.peerManager.updateOnlineStatus(p3.b58String, isOnline: true)
                manager.peerManager.updateSyncIDs(p3.b58String, syncIDs: [syncID!])
            }
        }

        // 添加文件夹
        let folder1 = TestHelpers.createTestSyncFolder(syncID: syncID, localPath: tempDir1)
        syncManager1.addFolder(folder1)

        let folder2 = TestHelpers.createTestSyncFolder(syncID: syncID, localPath: tempDir2)
        syncManager2.addFolder(folder2)

        let folder3 = TestHelpers.createTestSyncFolder(syncID: syncID, localPath: tempDir3)
        syncManager3.addFolder(folder3)

        // 等待文件夹添加和发现
        try? await Task.sleep(nanoseconds: folderDiscoveryWait)
    }

    override func tearDown() async throws {
        // 使用带超时的安全停止方式
        await stopP2PNodeSafely(syncManager1)
        await stopP2PNodeSafely(syncManager2)
        await stopP2PNodeSafely(syncManager3)

        syncManager1 = nil
        syncManager2 = nil
        syncManager3 = nil

        if tempDir1 != nil { TestHelpers.cleanupTempDirectory(tempDir1) }
        if tempDir2 != nil { TestHelpers.cleanupTempDirectory(tempDir2) }
        if tempDir3 != nil { TestHelpers.cleanupTempDirectory(tempDir3) }

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
                try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
            }
            group.addTask { try? await Task.sleep(nanoseconds: timeout) }
            for await _ in group {
                group.cancelAll()
                break
            }
        }
    }

    /// 获取同步文件夹（客户端1）
    var folder1: SyncFolder? {
        syncManager1.folders.first(where: { $0.syncID == syncID })
    }

    /// 获取同步文件夹（客户端2）
    var folder2: SyncFolder? {
        syncManager2.folders.first(where: { $0.syncID == syncID })
    }

    /// 获取同步文件夹（客户端3）
    var folder3: SyncFolder? {
        syncManager3.folders.first(where: { $0.syncID == syncID })
    }

    /// 触发客户端1同步并等待完成
    func triggerSyncFromClient1(timeout: TimeInterval = 25.0) async -> Bool {
        guard let folder = folder1 else { return false }
        return await TestHelpers.triggerSyncAndWait(
            syncManager: syncManager1, folder: folder, timeout: timeout)
    }

    /// 触发客户端2同步并等待完成
    func triggerSyncFromClient2(timeout: TimeInterval = 25.0) async -> Bool {
        guard let folder = folder2 else { return false }
        return await TestHelpers.triggerSyncAndWait(
            syncManager: syncManager2, folder: folder, timeout: timeout)
    }

    /// 触发客户端3同步并等待完成
    func triggerSyncFromClient3(timeout: TimeInterval = 25.0) async -> Bool {
        guard let folder = folder3 else { return false }
        return await TestHelpers.triggerSyncAndWait(
            syncManager: syncManager3, folder: folder, timeout: timeout)
    }

    /// 等待文件在所有客户端同步
    func waitForFileInAllClients(filename: String, timeout: TimeInterval = 30.0) async -> Bool {
        let file1 = tempDir1.appendingPathComponent(filename)
        let file2 = tempDir2.appendingPathComponent(filename)
        let file3 = tempDir3.appendingPathComponent(filename)

        return await TestHelpers.waitForCondition(timeout: timeout) {
            TestHelpers.fileExists(at: file1)
                && TestHelpers.fileExists(at: file2)
                && TestHelpers.fileExists(at: file3)
        }
    }

    /// 等待文件内容在所有客户端一致
    func waitForFileContentInAllClients(
        filename: String, expectedContent: String, timeout: TimeInterval = 30.0
    ) async -> Bool {
        let file1 = tempDir1.appendingPathComponent(filename)
        let file2 = tempDir2.appendingPathComponent(filename)
        let file3 = tempDir3.appendingPathComponent(filename)

        return await TestHelpers.waitForCondition(timeout: timeout) {
            guard let c1 = try? TestHelpers.readFileContent(at: file1),
                let c2 = try? TestHelpers.readFileContent(at: file2),
                let c3 = try? TestHelpers.readFileContent(at: file3)
            else { return false }
            return c1 == expectedContent && c2 == expectedContent && c3 == expectedContent
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

    // MARK: - 断言辅助方法

    /// 断言文件在所有客户端存在
    func assertExistsInAllClients(filename: String, timeout: TimeInterval = 30.0) async {
        let success = await waitForFileInAllClients(filename: filename, timeout: timeout)
        XCTAssertTrue(success, "文件 \(filename) 应该在所有客户端中存在")
    }

    /// 断言文件内容在所有客户端一致
    func assertContentInAllClients(filename: String, expected: String, timeout: TimeInterval = 30.0)
        async
    {
        let success = await waitForFileContentInAllClients(
            filename: filename, expectedContent: expected, timeout: timeout)
        XCTAssertTrue(success, "文件 \(filename) 内容应该在所有客户端中一致为: \(expected)")
    }
}
