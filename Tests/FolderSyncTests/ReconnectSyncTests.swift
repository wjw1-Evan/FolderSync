import Foundation
import XCTest

@testable import FolderSync

/// 重新上线与网络恢复测试 (精简版)
@MainActor
final class ReconnectSyncTests: TwoClientTestCase {

    override var folderDiscoveryWait: UInt64 { TestDuration.longSync }

    /// 测试离线期间的复杂操作流（增加、修改、删除、重命名、重新创建）在上线后同步
    func testComplexOfflineOperations() async throws {
        try await simulateClient2Offline()
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // 1. 产生一系列离线操作
        try await createFile(in: tempDir1, name: "batch1.txt", content: "A", wait: 0)
        try await createFile(in: tempDir1, name: "batch2.txt", content: "B", wait: 0)
        try await createFile(in: tempDir1, name: "to_delete.txt", content: "D", wait: 500_000_000)
        try await deleteFile(in: tempDir1, name: "to_delete.txt", wait: 500_000_000)
        try await renameFile(
            in: tempDir1, from: "batch2.txt", to: "batch2_renamed.txt", wait: 500_000_000)

        // 2. 删除后重新创建 (Resurrection)
        try await createFile(in: tempDir1, name: "resurrect.txt", content: "Old", wait: 500_000_000)
        try await deleteFile(in: tempDir1, name: "resurrect.txt", wait: 500_000_000)
        try await createFile(
            in: tempDir1, name: "resurrect.txt", content: "New", wait: 1_000_000_000)

        // 3. 上线并验证收敛
        try await simulateClient2Online()
        await waitDiscoveryAndTriggerSyncFromClient1()

        try await assertContent(in: tempDir2, name: "batch1.txt", expected: "A")
        try await assertContent(in: tempDir2, name: "batch2_renamed.txt", expected: "B")
        await assertNotExists(in: tempDir2, name: "to_delete.txt")
        await assertNotExists(in: tempDir2, name: "batch2.txt")
        try await assertContent(in: tempDir2, name: "resurrect.txt", expected: "New")
    }

    /// 测试状态同步一致性（向量钟与删除记录）
    func testStateSyncConsistency() async throws {
        try await createFile(in: tempDir1, name: "state.txt", content: "V1", wait: 3_000_000_000)
        await assertExists(in: tempDir2, name: "state.txt")

        try await simulateClient2Offline()
        try await modifyFile(in: tempDir1, name: "state.txt", content: "V2", wait: 500_000_000)
        try await deleteFile(in: tempDir1, name: "state.txt", wait: 1_000_000_000)

        try await simulateClient2Online()
        await waitDiscoveryAndTriggerSyncFromClient1()

        await assertNotExists(in: tempDir2, name: "state.txt")
        let hasDeletionRecord = await TestHelpers.waitForCondition(timeout: 10.0) {
            self.syncManager2.deletedPaths(for: self.syncID).contains("state.txt")
        }
        XCTAssertTrue(hasDeletionRecord, "删除记录应同步")
    }

    /// 测试网络中断与多次重连的稳定性
    func testNetworkStabilityAndInterruption() async throws {
        let largeData = TestHelpers.generateLargeFileData(sizeInMB: 1)
        try TestHelpers.createTestFile(
            at: tempDir1.appendingPathComponent("stability.bin"), data: largeData)

        // 第一次离线/上线
        try await simulateClient2Offline()
        try await simulateClient2Online()

        // 第二次离线
        try await simulateClient2Offline()
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // 第三次上线并同步
        try await simulateClient2Online()
        await waitDiscoveryAndTriggerSyncFromClient1()

        let syncedFile = tempDir2.appendingPathComponent("stability.bin")
        await assertExists(in: tempDir2, name: "stability.bin", timeout: 25.0)
        let syncedData = try TestHelpers.readFileData(at: syncedFile)
        XCTAssertEqual(syncedData, largeData, "内容应在多次干扰后保持一致")
    }
}
