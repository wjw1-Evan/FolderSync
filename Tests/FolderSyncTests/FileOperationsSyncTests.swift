import Foundation
import XCTest

@testable import FolderSync

/// 核心文件操作同步测试 (精简版)
final class FileOperationsSyncTests: TwoClientTestCase {

    override var folderDiscoveryWait: UInt64 { TestDuration.longSync }

    /// 1. 测试基础文件生命周期 (增、删、改)
    func testFileLifecycle() async throws {
        // 增加
        try await createFile(in: tempDir1, name: "lifecycle.txt", content: "V1")
        await assertExists(in: tempDir2, name: "lifecycle.txt")
        // 修改
        try await modifyFile(in: tempDir1, name: "lifecycle.txt", content: "V2")
        try await assertContent(in: tempDir2, name: "lifecycle.txt", expected: "V2")
        // 删除
        try await deleteFile(in: tempDir1, name: "lifecycle.txt")
        await assertNotExists(in: tempDir2, name: "lifecycle.txt")
    }

    /// 2. 测试目录综合操作 (嵌套添加、复制、重命名)
    func testFolderOperationsSuite() async throws {
        // 准备包含内容的子目录
        let subDir = tempDir1.appendingPathComponent("suite")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try TestHelpers.createTestFile(at: subDir.appendingPathComponent("f1.txt"), content: "1")
        try await Task.sleep(nanoseconds: 6_000_000_000)
        await assertDirectoryExists(in: tempDir2, name: "suite")

        // 复制目录
        let destDir = tempDir1.appendingPathComponent("suite_copy")
        try FileManager.default.copyItem(at: subDir, to: destDir)
        try await Task.sleep(nanoseconds: 6_000_000_000)
        await assertDirectoryExists(in: tempDir2, name: "suite_copy")

        // 重命名目录
        try await renameFile(in: tempDir1, from: "suite_copy", to: "suite_renamed")
        await assertNotExists(in: tempDir2, name: "suite_copy")
        await assertDirectoryExists(in: tempDir2, name: "suite_renamed")
    }

    /// 3. 测试大文件块级修改与重命名哈希匹配
    func testAdvancedSyncLogic() async throws {
        // 大文件修改
        let largeFile = tempDir1.appendingPathComponent("large.bin")
        let data1 = TestHelpers.generateLargeFileData(sizeInMB: 2)
        try TestHelpers.createTestFile(at: largeFile, data: data1)
        try await Task.sleep(nanoseconds: 12_000_000_000)

        var data2 = data1
        data2.replaceSubrange(0..<100, with: Data(repeating: 0xEE, count: 100))
        try TestHelpers.createTestFile(at: largeFile, data: data2)
        try await Task.sleep(nanoseconds: 15_000_000_000)

        let syncedData = try TestHelpers.readFileData(
            at: tempDir2.appendingPathComponent("large.bin"))
        XCTAssertEqual(syncedData.prefix(100), data2.prefix(100))

        // 哈希重命名匹配
        let content = "Unique content for hash matching"
        try await createFile(in: tempDir1, name: "h1.txt", content: content)
        await assertExists(in: tempDir2, name: "h1.txt")
        try await renameFile(in: tempDir1, from: "h1.txt", to: "h2.txt")
        await assertNotExists(in: tempDir2, name: "h1.txt")
        await assertExists(in: tempDir2, name: "h2.txt")
    }

    /// 4. 测试并发性能与防抖 (从 SyncOptimization/Trigger 整合)
    func testConcurrencyAndDebounce() async throws {
        // A. 大量小文件并发处理 (验证不死锁)
        let fileCount = 50  // 减少数量以平衡速度
        for i in 0..<fileCount {
            try TestHelpers.createTestFile(
                at: tempDir1.appendingPathComponent("perf_\(i).txt"), content: "c\(i)")
        }
        try? await Task.sleep(nanoseconds: 10_000_000_000)

        let allAdded = await TestHelpers.waitForCondition(timeout: 30.0) {
            TestHelpers.getAllFiles(in: self.tempDir2).filter {
                $0.lastPathComponent.contains("perf_")
            }.count >= fileCount
        }
        XCTAssertTrue(allAdded, "大量小文件应能正确同步且不死锁")

        // B. 批量变更防抖
        for i in 1...10 {
            try TestHelpers.createTestFile(
                at: tempDir1.appendingPathComponent("batch_\(i).txt"), content: "B")
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        await assertExists(in: tempDir2, name: "batch_10.txt")
    }

    /// 5. 测试特殊边界条件 (特殊字符, 嵌套, 符号链接)
    func testEdgeCaseSuite() async throws {
        // 特殊文件名与深层嵌套
        let specialName = "中文_spaces_@#$.txt"
        var deepPath = tempDir1!
        for i in 1...5 { deepPath = deepPath.appendingPathComponent("D\(i)") }
        try FileManager.default.createDirectory(at: deepPath, withIntermediateDirectories: true)
        try await createFile(in: deepPath, name: specialName, content: "Edge", wait: 8_000_000_000)

        var syncedPath = tempDir2!
        for i in 1...5 { syncedPath = syncedPath.appendingPathComponent("D\(i)") }
        await assertExists(in: syncedPath, name: specialName)

        // 零字节与符号链接
        try await createFile(in: tempDir1, name: "zero.txt", content: "", wait: 2_000_000_000)
        await assertExists(in: tempDir2, name: "zero.txt")

        let symlink = tempDir1.appendingPathComponent("link.txt")
        try? FileManager.default.createSymbolicLink(
            at: symlink, withDestinationURL: tempDir1.appendingPathComponent("zero.txt"))
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await assertExists(in: tempDir2, name: "link.txt")
    }
}
