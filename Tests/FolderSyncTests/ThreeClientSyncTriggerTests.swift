import Foundation
import XCTest

@testable import FolderSync

/// 三客户端同步触发测试
/// 验证多设备之间的同步触发机制
@MainActor
final class ThreeClientSyncTriggerTests: ThreeClientTestCase {

    // MARK: - 一对多同步测试

    /// 测试客户端A变更，B和C都收到同步
    func testOneToManySyncTrigger() async throws {
        // 客户端1创建文件
        let testFile = tempDir1.appendingPathComponent("one_to_many.txt")
        try TestHelpers.createTestFile(at: testFile, content: "From client 1 to all")

        // 等待 FSEvents 检测变更并触发同步
        try await Task.sleep(nanoseconds: 6_000_000_000)  // 6秒

        // 手动触发同步确保传播
        _ = await triggerSyncFromClient1(timeout: 25.0)

        // 验证文件同步到客户端2和客户端3
        let file2 = tempDir2.appendingPathComponent("one_to_many.txt")
        let file3 = tempDir3.appendingPathComponent("one_to_many.txt")

        let syncedToAll = await TestHelpers.waitForCondition(timeout: 35.0) {
            TestHelpers.fileExists(at: file2) && TestHelpers.fileExists(at: file3)
        }

        XCTAssertTrue(syncedToAll, "文件应同步到客户端2和客户端3")

        if syncedToAll {
            let content2 = try TestHelpers.readFileContent(at: file2)
            let content3 = try TestHelpers.readFileContent(at: file3)
            XCTAssertEqual(content2, "From client 1 to all", "客户端2文件内容应正确")
            XCTAssertEqual(content3, "From client 1 to all", "客户端3文件内容应正确")
        }
    }

    /// 测试客户端B和C同时变更，A收到两边的文件
    func testManyToOneSyncTrigger() async throws {
        // 客户端2创建文件1
        let file2 = tempDir2.appendingPathComponent("from_client2.txt")
        try TestHelpers.createTestFile(at: file2, content: "File from client 2")

        // 客户端3创建文件2
        let file3 = tempDir3.appendingPathComponent("from_client3.txt")
        try TestHelpers.createTestFile(at: file3, content: "File from client 3")

        // 等待同步
        try await Task.sleep(nanoseconds: 8_000_000_000)  // 8秒

        // 手动触发同步
        _ = await triggerSyncFromClient2(timeout: 25.0)
        _ = await triggerSyncFromClient3(timeout: 25.0)
        _ = await triggerSyncFromClient1(timeout: 25.0)

        // 验证客户端1收到两边的文件
        let syncedFile2 = tempDir1.appendingPathComponent("from_client2.txt")
        let syncedFile3 = tempDir1.appendingPathComponent("from_client3.txt")

        let bothSynced = await TestHelpers.waitForCondition(timeout: 35.0) {
            TestHelpers.fileExists(at: syncedFile2) && TestHelpers.fileExists(at: syncedFile3)
        }

        XCTAssertTrue(bothSynced, "客户端1应收到客户端2和客户端3的文件")

        if bothSynced {
            let content2 = try TestHelpers.readFileContent(at: syncedFile2)
            let content3 = try TestHelpers.readFileContent(at: syncedFile3)
            XCTAssertEqual(content2, "File from client 2", "文件2内容应正确")
            XCTAssertEqual(content3, "File from client 3", "文件3内容应正确")
        }
    }

    // MARK: - 链式同步测试

    /// 测试 A->B->C 链式同步
    func testChainedSyncTrigger() async throws {
        // 客户端1创建文件
        let testFile = tempDir1.appendingPathComponent("chained.txt")
        try TestHelpers.createTestFile(at: testFile, content: "Chained sync test")

        // 触发客户端1同步
        _ = await triggerSyncFromClient1(timeout: 25.0)

        // 等待文件同步到客户端2
        let file2 = tempDir2.appendingPathComponent("chained.txt")
        let syncedTo2 = await TestHelpers.waitForCondition(timeout: 25.0) {
            TestHelpers.fileExists(at: file2)
        }
        XCTAssertTrue(syncedTo2, "文件应首先同步到客户端2")

        // 触发客户端2同步（传播到客户端3）
        _ = await triggerSyncFromClient2(timeout: 25.0)

        // 验证文件同步到客户端3
        let file3 = tempDir3.appendingPathComponent("chained.txt")
        let syncedTo3 = await TestHelpers.waitForCondition(timeout: 25.0) {
            TestHelpers.fileExists(at: file3)
        }
        XCTAssertTrue(syncedTo3, "文件应通过链式同步到达客户端3")

        if syncedTo3 {
            let content = try TestHelpers.readFileContent(at: file3)
            XCTAssertEqual(content, "Chained sync test", "文件内容应一致")
        }
    }

    // MARK: - 同时变更测试

    /// 测试三端同时变更不同文件
    func testSimultaneousChanges() async throws {
        // 三个客户端同时创建不同文件
        let file1 = tempDir1.appendingPathComponent("sim_1.txt")
        try TestHelpers.createTestFile(at: file1, content: "Simultaneous 1")

        let file2 = tempDir2.appendingPathComponent("sim_2.txt")
        try TestHelpers.createTestFile(at: file2, content: "Simultaneous 2")

        let file3 = tempDir3.appendingPathComponent("sim_3.txt")
        try TestHelpers.createTestFile(at: file3, content: "Simultaneous 3")

        // 等待 FSEvents 检测变更
        try await Task.sleep(nanoseconds: 6_000_000_000)  // 6秒

        // 触发所有客户端同步
        _ = await triggerSyncFromClient1(timeout: 25.0)
        _ = await triggerSyncFromClient2(timeout: 25.0)
        _ = await triggerSyncFromClient3(timeout: 25.0)

        // 再次触发确保全部传播
        _ = await triggerSyncFromClient1(timeout: 25.0)

        // 验证所有文件在所有客户端都存在
        let filesToCheck = [
            ("sim_1.txt", "Simultaneous 1"),
            ("sim_2.txt", "Simultaneous 2"),
            ("sim_3.txt", "Simultaneous 3"),
        ]

        for (filename, expectedContent) in filesToCheck {
            let allSynced = await waitForFileContentInAllClients(
                filename: filename, expectedContent: expectedContent, timeout: 35.0)
            XCTAssertTrue(allSynced, "文件 \(filename) 应在所有客户端存在且内容正确")
        }
    }

    // MARK: - 文件修改传播测试

    /// 测试文件修改在三端传播
    func testFileModificationPropagation() async throws {
        // 客户端1创建文件
        let testFile = tempDir1.appendingPathComponent("modify_prop.txt")
        try TestHelpers.createTestFile(at: testFile, content: "Original content")

        // 等待初始同步
        _ = await triggerSyncFromClient1(timeout: 25.0)

        // 修改文件
        try TestHelpers.createTestFile(at: testFile, content: "Modified content")

        // 等待变更检测并同步
        try await Task.sleep(nanoseconds: 4_000_000_000)  // 4秒
        _ = await triggerSyncFromClient1(timeout: 25.0)

        // 验证修改同步到客户端2和客户端3
        let file2 = tempDir2.appendingPathComponent("modify_prop.txt")
        let file3 = tempDir3.appendingPathComponent("modify_prop.txt")

        let bothModified = await TestHelpers.waitForCondition(timeout: 30.0) {
            guard let c2 = try? TestHelpers.readFileContent(at: file2),
                let c3 = try? TestHelpers.readFileContent(at: file3)
            else { return false }
            return c2 == "Modified content" && c3 == "Modified content"
        }

        XCTAssertTrue(bothModified, "文件修改应同步到客户端2和客户端3")
    }

    // MARK: - 删除传播测试

    /// 测试文件删除在三端传播
    func testFileDeletionPropagation() async throws {
        // 客户端1创建文件
        let testFile = tempDir1.appendingPathComponent("delete_prop.txt")
        try TestHelpers.createTestFile(at: testFile, content: "To be deleted")

        // 等待初始同步到所有客户端
        _ = await triggerSyncFromClient1(timeout: 25.0)

        let file2 = tempDir2.appendingPathComponent("delete_prop.txt")
        let file3 = tempDir3.appendingPathComponent("delete_prop.txt")

        let allSynced = await TestHelpers.waitForCondition(timeout: 25.0) {
            TestHelpers.fileExists(at: file2) && TestHelpers.fileExists(at: file3)
        }
        XCTAssertTrue(allSynced, "初始文件应同步到所有客户端")

        // 删除文件
        try FileManager.default.removeItem(at: testFile)

        // 等待删除检测并同步
        try await Task.sleep(nanoseconds: 4_000_000_000)  // 4秒
        _ = await triggerSyncFromClient1(timeout: 25.0)

        // 验证删除同步到客户端2和客户端3
        let bothDeleted = await TestHelpers.waitForCondition(timeout: 25.0) {
            !TestHelpers.fileExists(at: file2) && !TestHelpers.fileExists(at: file3)
        }

        XCTAssertTrue(bothDeleted, "文件删除应同步到客户端2和客户端3")
    }
}
