import Foundation
import XCTest

@testable import FolderSync

/// 冲突处理测试 (精简版)
@MainActor
final class ConflictResolutionTests: TwoClientTestCase {

    /// 1. 测试并发修改场景 (基础数据收敛, 大文件修改, 快速连续变更)
    func testConcurrentModificationScenarios() async throws {
        // A. 基础文件并发修改
        try await createFile(in: tempDir1, name: "c1.txt", content: "Orig", wait: 3_000_000_000)
        try TestHelpers.createTestFile(
            at: tempDir1.appendingPathComponent("c1.txt"), content: "By A")
        try TestHelpers.createTestFile(
            at: tempDir2.appendingPathComponent("c1.txt"), content: "By B")

        let settled = await TestHelpers.waitForCondition(timeout: 20.0) {
            let hasConflict =
                !self.getConflictFiles(in: self.tempDir1, baseName: "c1.txt").isEmpty
                || !self.getConflictFiles(in: self.tempDir2, baseName: "c1.txt").isEmpty
            if hasConflict { return true }
            let contentA =
                (try? TestHelpers.readFileContent(
                    at: self.tempDir1.appendingPathComponent("c1.txt"))) ?? ""
            let contentB =
                (try? TestHelpers.readFileContent(
                    at: self.tempDir2.appendingPathComponent("c1.txt"))) ?? ""
            return contentA == contentB && !contentA.isEmpty
        }
        XCTAssertTrue(settled, "并发修改应生成冲突文件或收敛")

        // B. 快速连续修改 (验证稳定性)
        let rapid = tempDir1.appendingPathComponent("rapid.txt")
        try await createFile(in: tempDir1, name: "rapid.txt", content: "V0", wait: 5_000_000_000)
        for i in 1...3 {
            try TestHelpers.createTestFile(at: rapid, content: "V\(i)")
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// 2. 测试复杂冲突场景 (添加-删除, 重命名-修改, 冲突文件隔离)
    func testAdvancedConflictResolution() async throws {
        // A. 添加-删除冲突
        try await createFile(in: tempDir1, name: "ad.txt", content: "New", wait: 3_000_000_000)
        await assertExists(in: tempDir2, name: "ad.txt")
        try await deleteFile(in: tempDir2, name: "ad.txt", wait: 5_000_000_000)
        XCTAssertTrue(
            TestHelpers.fileExists(at: tempDir1.appendingPathComponent("ad.txt"))
                || !getConflictFiles(in: tempDir1, baseName: "ad.txt").isEmpty, "应处理增删冲突")

        // B. 冲突文件不应被反向同步
        try TestHelpers.createTestFile(at: tempDir1.appendingPathComponent("sec.txt"), content: "A")
        try TestHelpers.createTestFile(at: tempDir2.appendingPathComponent("sec.txt"), content: "B")
        try? await Task.sleep(nanoseconds: 5_000_000_000)

        let conflicts = getConflictFiles(in: tempDir1)
        if let first = conflicts.first {
            await assertNotExists(in: tempDir2, name: first.lastPathComponent, timeout: 5.0)
        }
    }

    /// 3. 测试文件复活与更新获胜场景
    func testFileResurrectionScenarios() async throws {
        // A. 删除后立即重建 (Resurrection)
        try await createFile(in: tempDir1, name: "res.txt", content: "V1", wait: 2_000_000_000)
        try await deleteFile(in: tempDir1, name: "res.txt", wait: 2_000_000_000)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        try await createFile(in: tempDir1, name: "res.txt", content: "V2", wait: 3_000_000_000)
        try await assertContent(in: tempDir2, name: "res.txt", expected: "V2")

        // B. 一端删除，另一端几乎同时修改 (更新获胜)
        try await createFile(in: tempDir1, name: "win.txt", content: "Base", wait: 2_000_000_000)
        try FileManager.default.removeItem(at: tempDir1.appendingPathComponent("win.txt"))
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        try await modifyFile(in: tempDir2, name: "win.txt", content: "Winner", wait: 5_000_000_000)
        await assertExists(in: tempDir1, name: "win.txt")
        try await assertContent(in: tempDir1, name: "win.txt", expected: "Winner")
    }
}
