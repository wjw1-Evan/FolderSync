import Foundation
import XCTest

@testable import FolderSync

/// 同步触发机制测试
/// 验证文件变更后能正确触发同步
@MainActor
final class SyncTriggerTests: TwoClientTestCase {

    /// 双节点需更长时间完成发现与注册
    override var folderDiscoveryWait: UInt64 { TestDuration.longSync }

    // MARK: - 文件变更触发同步测试

    /// 测试文件变更后自动触发同步
    func testSyncTriggerAfterFileChange() async throws {
        // 客户端1创建文件
        let testFile = tempDir1.appendingPathComponent("trigger_test.txt")
        try TestHelpers.createTestFile(at: testFile, content: "Trigger test content")

        // 等待 FSEvents 检测变更并触发同步
        try await Task.sleep(nanoseconds: 6_000_000_000)  // 6秒

        // 验证文件已同步到客户端2
        let syncedFile = tempDir2.appendingPathComponent("trigger_test.txt")
        let fileExists = await TestHelpers.waitForCondition(timeout: 28.0) {
            TestHelpers.fileExists(at: syncedFile)
        }

        XCTAssertTrue(fileExists, "文件变更后应自动触发同步")

        if fileExists {
            let content = try TestHelpers.readFileContent(at: syncedFile)
            XCTAssertEqual(content, "Trigger test content", "文件内容应一致")
        }
    }

    /// 测试批量文件变更后触发一次同步（防抖机制）
    func testSyncTriggerAfterMultipleFileChanges() async throws {
        // 快速创建多个文件
        for i in 1...5 {
            let file = tempDir1.appendingPathComponent("batch_\(i).txt")
            try TestHelpers.createTestFile(at: file, content: "Batch file \(i)")
            // 每个文件之间间隔 100ms
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // 等待防抖完成后的同步
        try await Task.sleep(nanoseconds: 8_000_000_000)  // 8秒

        // 验证所有文件都已同步
        var allSynced = true
        for i in 1...5 {
            let syncedFile = tempDir2.appendingPathComponent("batch_\(i).txt")
            let exists = await TestHelpers.waitForCondition(timeout: 28.0) {
                TestHelpers.fileExists(at: syncedFile)
            }
            if !exists {
                allSynced = false
                XCTFail("文件 batch_\(i).txt 应该已同步")
            }
        }

        XCTAssertTrue(allSynced, "所有批量文件应通过一次同步完成")
    }

    /// 测试手动调用 triggerSync 触发同步
    func testManualSyncTrigger() async throws {
        // 客户端1创建文件但不依赖 FSEvents
        let testFile = tempDir1.appendingPathComponent("manual_trigger.txt")
        try TestHelpers.createTestFile(at: testFile, content: "Manual trigger content")

        // 手动触发同步
        if let folder1 = syncManager1.folders.first(where: { $0.syncID == syncID }) {
            let syncCompleted = await TestHelpers.triggerSyncAndWait(
                syncManager: syncManager1, folder: folder1, timeout: 25.0)
            XCTAssertTrue(syncCompleted, "手动触发的同步应完成")
        }

        // 验证文件已同步
        let syncedFile = tempDir2.appendingPathComponent("manual_trigger.txt")
        let fileExists = await TestHelpers.waitForCondition(timeout: 10.0) {
            TestHelpers.fileExists(at: syncedFile)
        }

        XCTAssertTrue(fileExists, "手动触发同步后文件应已同步")
    }

    /// 测试对等点在线时触发同步成功
    func testSyncTriggerWithOnlinePeer() async throws {
        // 验证两个客户端都在线
        let peerCount1 = syncManager1.peerManager.allPeers.count
        let peerCount2 = syncManager2.peerManager.allPeers.count

        // 至少应发现对方
        let peersDiscovered = await TestHelpers.waitForCondition(timeout: 15.0) {
            self.syncManager1.peerManager.allPeers.count >= 1
                && self.syncManager2.peerManager.allPeers.count >= 1
        }

        XCTAssertTrue(
            peersDiscovered, "两个客户端应互相发现 (client1: \(peerCount1), client2: \(peerCount2))")

        // 创建文件并触发同步
        let testFile = tempDir1.appendingPathComponent("online_peer_test.txt")
        try TestHelpers.createTestFile(at: testFile, content: "Online peer sync")

        // 手动触发同步
        if let folder1 = syncManager1.folders.first(where: { $0.syncID == syncID }) {
            _ = await TestHelpers.triggerSyncAndWait(
                syncManager: syncManager1, folder: folder1, timeout: 25.0)
        }

        // 验证文件已同步
        let syncedFile = tempDir2.appendingPathComponent("online_peer_test.txt")
        let fileExists = await TestHelpers.waitForCondition(timeout: 15.0) {
            TestHelpers.fileExists(at: syncedFile)
        }

        XCTAssertTrue(fileExists, "对等点在线时应成功同步")
    }

    /// 测试对等点离线时不触发同步（或同步失败但不崩溃）
    func testSyncTriggerWithOfflinePeer() async throws {
        // 停止客户端2的 P2P 节点
        try await simulateClient2Offline()

        // 等待状态更新
        try await Task.sleep(nanoseconds: 2_000_000_000)  // 2秒

        // 创建文件
        let testFile = tempDir1.appendingPathComponent("offline_peer_test.txt")
        try TestHelpers.createTestFile(at: testFile, content: "Offline peer test")

        // 尝试触发同步（不应崩溃）
        if let folder1 = syncManager1.folders.first(where: { $0.syncID == syncID }) {
            syncManager1.triggerSync(for: folder1)
        }

        // 等待一段时间
        try await Task.sleep(nanoseconds: 5_000_000_000)  // 5秒

        // 文件不应同步到客户端2（因为它离线了）
        let syncedFile = tempDir2.appendingPathComponent("offline_peer_test.txt")
        XCTAssertFalse(
            TestHelpers.fileExists(at: syncedFile), "对等点离线时文件不应同步（或同步应安全失败）")
    }

    // MARK: - 双向同步触发测试

    /// 测试双向同步：两个客户端同时创建不同文件
    func testBidirectionalSyncTrigger() async throws {
        // 客户端1创建文件1
        let file1 = tempDir1.appendingPathComponent("bidirect_1.txt")
        try TestHelpers.createTestFile(at: file1, content: "From client 1")

        // 客户端2创建文件2
        let file2 = tempDir2.appendingPathComponent("bidirect_2.txt")
        try TestHelpers.createTestFile(at: file2, content: "From client 2")

        // 等待双向同步
        try await Task.sleep(nanoseconds: 8_000_000_000)  // 8秒

        // 验证两个文件都在两个客户端存在
        let file1InClient2 = tempDir2.appendingPathComponent("bidirect_1.txt")
        let file2InClient1 = tempDir1.appendingPathComponent("bidirect_2.txt")

        let bothSynced = await TestHelpers.waitForCondition(timeout: 28.0) {
            TestHelpers.fileExists(at: file1InClient2) && TestHelpers.fileExists(at: file2InClient1)
        }

        XCTAssertTrue(bothSynced, "双向同步应使两个文件都在两个客户端存在")

        if bothSynced {
            let content1 = try TestHelpers.readFileContent(at: file1InClient2)
            let content2 = try TestHelpers.readFileContent(at: file2InClient1)
            XCTAssertEqual(content1, "From client 1", "文件1内容应正确")
            XCTAssertEqual(content2, "From client 2", "文件2内容应正确")
        }
    }

    /// 测试同步完成后的状态
    func testSyncStatusAfterCompletion() async throws {
        // 创建文件
        let testFile = tempDir1.appendingPathComponent("status_test.txt")
        try TestHelpers.createTestFile(at: testFile, content: "Status test")

        // 触发同步并等待完成
        if let folder1 = syncManager1.folders.first(where: { $0.syncID == syncID }) {
            let completed = await TestHelpers.triggerSyncAndWait(
                syncManager: syncManager1, folder: folder1, timeout: 25.0)
            XCTAssertTrue(completed, "同步应完成")

            // 验证同步后状态
            if let updatedFolder = syncManager1.folders.first(where: { $0.id == folder1.id }) {
                XCTAssertEqual(updatedFolder.status, .synced, "同步完成后状态应为 .synced")
            }
        }
    }
}
