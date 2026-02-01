import Foundation
import XCTest

@testable import FolderSync

/// 三客户端同步触发测试 (精简版)
@MainActor
final class ThreeClientSyncTriggerTests: ThreeClientTestCase {

    /// 测试多端数据传播（一对多广播与多对一汇聚）
    func testMultiNodeDataPropagation() async throws {
        // 1. 一对多广播
        try await createFile(in: tempDir1, name: "broadcast.txt", content: "From 1", wait: 0)
        _ = await triggerSyncFromClient1()
        await assertContentInAllClients(filename: "broadcast.txt", expected: "From 1")

        // 2. 多对一汇聚
        try await createFile(in: tempDir2, name: "from2.txt", content: "C2", wait: 0)
        try await createFile(in: tempDir3, name: "from3.txt", content: "C3", wait: 5_000_000_000)

        _ = await triggerSyncFromClient2()
        _ = await triggerSyncFromClient3()
        _ = await triggerSyncFromClient1()

        await assertContent(in: tempDir1, name: "from2.txt", expected: "C2")
        await assertContent(in: tempDir1, name: "from3.txt", expected: "C3")
    }

    /// 测试链式同步与并发非冲突修改
    func testChainAndSimultaneousChanges() async throws {
        // 1. 链式同步 A -> B -> C
        try await createFile(in: tempDir1, name: "chain.txt", content: "Chain", wait: 0)
        _ = await triggerSyncFromClient1()
        await assertExists(in: tempDir2, name: "chain.txt")
        _ = await triggerSyncFromClient2()
        await assertExists(in: tempDir3, name: "chain.txt")

        // 2. 同时变更不同文件并传播
        try await createFile(in: tempDir1, name: "sim1.txt", content: "S1", wait: 0)
        try await createFile(in: tempDir2, name: "sim2.txt", content: "S2", wait: 0)
        try await createFile(in: tempDir3, name: "sim3.txt", content: "S3", wait: 6_000_000_000)

        _ = await triggerSyncFromClient1()
        _ = await triggerSyncFromClient2()
        _ = await triggerSyncFromClient3()
        _ = await triggerSyncFromClient1()  // 最终汇聚

        await assertContentInAllClients(filename: "sim1.txt", expected: "S1")
        await assertContentInAllClients(filename: "sim2.txt", expected: "S2")
        await assertContentInAllClients(filename: "sim3.txt", expected: "S3")
    }

    // MARK: - 内部断言辅助 (避免与基类冲突)

    private func assertExists(in dir: URL, name: String, timeout: TimeInterval = 28.0) async {
        let exists = await TestHelpers.waitForCondition(timeout: timeout) {
            TestHelpers.fileExists(at: dir.appendingPathComponent(name))
        }
        XCTAssertTrue(exists, "文件 \(name) 应存在于 \(dir.lastPathComponent)")
    }

    private func assertContent(
        in dir: URL, name: String, expected: String, timeout: TimeInterval = 28.0
    ) async {
        let success = await TestHelpers.waitForCondition(timeout: timeout) {
            (try? TestHelpers.readFileContent(at: dir.appendingPathComponent(name))) == expected
        }
        XCTAssertTrue(success, "文件 \(name) 内容应为: \(expected)")
    }
}
