import XCTest
import Foundation
@testable import FolderSync

/// 同步逻辑优化相关测试
/// 覆盖：calculateFullState 并发控制、预计算状态复用、统一下载阶段、FastCDC 复用等
@MainActor
final class SyncOptimizationTests: XCTestCase {
    var tempDir: URL!
    var syncManager: SyncManager!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = try TestHelpers.createTempDirectory()
        syncManager = SyncManager()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    override func tearDown() async throws {
        try? await syncManager?.p2pNode.stop()
        syncManager = nil
        TestHelpers.cleanupTempDirectory(tempDir)
        try await super.tearDown()
    }

    // MARK: - calculateFullState / FolderStatistics

    /// 多文件下 calculateFullState 不死锁、不丢文件（TaskGroup 并发控制与 activeTasks 修复）
    func testCalculateFullState_ManyFiles_NoDeadlock() async throws {
        let fileCount = 120
        for i in 0..<fileCount {
            let f = tempDir.appendingPathComponent("file_\(i).txt")
            try TestHelpers.createTestFile(at: f, content: "content \(i)")
        }
        let folder = TestHelpers.createTestSyncFolder(
            syncID: "test\(UUID().uuidString.prefix(8))",
            localPath: tempDir
        )
        syncManager.addFolder(folder)

        let (_, metadata, folderCount, totalSize) = await syncManager.calculateFullState(for: folder)

        XCTAssertEqual(metadata.count, fileCount, "文件数量应与创建的一致")
        XCTAssertGreaterThanOrEqual(totalSize, 0)
        XCTAssertGreaterThanOrEqual(folderCount, 0)
    }

    /// 空文件夹 calculateFullState 正常返回
    func testCalculateFullState_EmptyFolder() async throws {
        let emptyDir = try TestHelpers.createTempDirectory()
        defer { TestHelpers.cleanupTempDirectory(emptyDir) }
        let folder = TestHelpers.createTestSyncFolder(
            syncID: "test\(UUID().uuidString.prefix(8))",
            localPath: emptyDir
        )
        syncManager.addFolder(folder)

        let (mst, metadata, folderCount, totalSize) = await syncManager.calculateFullState(for: folder)

        XCTAssertTrue(metadata.isEmpty)
        XCTAssertEqual(folderCount, 0)
        XCTAssertEqual(totalSize, 0)
        XCTAssertNil(mst.rootHash)
    }

    // MARK: - triggerSync + 预计算状态（多 peer 路径）

    /// 双端同时 triggerSync：预计算状态复用路径可正常完成同步
    func testTriggerSync_TwoPeers_Completes() async throws {
        let temp1 = try TestHelpers.createTempDirectory()
        let temp2 = try TestHelpers.createTempDirectory()
        defer { TestHelpers.cleanupTempDirectory(temp1); TestHelpers.cleanupTempDirectory(temp2) }

        let sm1 = SyncManager()
        let sm2 = SyncManager()

        let syncID = "test\(UUID().uuidString.prefix(8))"
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let folder1 = TestHelpers.createTestSyncFolder(syncID: syncID, localPath: temp1)
        let folder2 = TestHelpers.createTestSyncFolder(syncID: syncID, localPath: temp2)
        sm1.addFolder(folder1)
        sm2.addFolder(folder2)
        try? await Task.sleep(nanoseconds: 5_000_000_000)

        try TestHelpers.createTestFile(at: temp1.appendingPathComponent("shared.txt"), content: "from peer 1")
        let ok = await TestHelpers.triggerSyncAndWait(syncManager: sm1, folder: folder1, timeout: 25.0)
        XCTAssertTrue(ok, "triggerSync 应完成且状态为 synced")

        let exists = await TestHelpers.waitForCondition(timeout: 15.0) {
            TestHelpers.fileExists(at: temp2.appendingPathComponent("shared.txt"))
        }
        XCTAssertTrue(exists, "文件应同步到对端")

        try? await sm1.p2pNode.stop()
        try? await sm2.p2pNode.stop()
    }

    // MARK: - 块级同步（FastCDC 复用）

    /// 大文件块级同步仍正确（FastCDC 复用不影响结果）
    func testChunkSync_LargeFile_StillCorrect() async throws {
        let temp1 = try TestHelpers.createTempDirectory()
        let temp2 = try TestHelpers.createTempDirectory()
        defer { TestHelpers.cleanupTempDirectory(temp1); TestHelpers.cleanupTempDirectory(temp2) }

        let sm1 = SyncManager()
        let sm2 = SyncManager()

        let syncID = "test\(UUID().uuidString.prefix(8))"
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let folder1 = TestHelpers.createTestSyncFolder(syncID: syncID, localPath: temp1)
        let folder2 = TestHelpers.createTestSyncFolder(syncID: syncID, localPath: temp2)
        sm1.addFolder(folder1)
        sm2.addFolder(folder2)
        try? await Task.sleep(nanoseconds: 5_000_000_000)

        let large = temp1.appendingPathComponent("large.bin")
        let data = TestHelpers.generateLargeFileData(sizeInMB: 2)
        try TestHelpers.createTestFile(at: large, data: data)

        let ok = await TestHelpers.triggerSyncAndWait(syncManager: sm1, folder: folder1, timeout: 40.0)
        XCTAssertTrue(ok, "大文件同步应完成")

        let remote = temp2.appendingPathComponent("large.bin")
        let received = await TestHelpers.waitForCondition(timeout: 20.0) {
            TestHelpers.fileExists(at: remote)
        }
        XCTAssertTrue(received, "大文件应出现在对端")
        if received {
            let remoteData = try TestHelpers.readFileData(at: remote)
            XCTAssertEqual(remoteData.count, data.count)
            XCTAssertEqual(remoteData, data)
        }

        try? await sm1.p2pNode.stop()
        try? await sm2.p2pNode.stop()
    }
}
