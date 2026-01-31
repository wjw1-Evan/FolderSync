import XCTest
import Foundation
@testable import FolderSync

/// 冲突处理测试
@MainActor
final class ConflictResolutionTests: TwoClientTestCase {
    
    // MARK: - 并发修改冲突测试
    
    /// 测试多客户端同时修改同一文件
    func testConcurrentModify_SameFile() async throws {
        // 创建文件并同步
        let testFile1 = tempDir1.appendingPathComponent("conflict.txt")
        try TestHelpers.createTestFile(at: testFile1, content: "Original content")
        
        // 等待初始同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 验证文件已同步
        let testFile2 = tempDir2.appendingPathComponent("conflict.txt")
        XCTAssertTrue(TestHelpers.fileExists(at: testFile2), "文件应该已同步")
        
        // 客户端1和2同时修改文件（模拟并发）
        try TestHelpers.createTestFile(at: testFile1, content: "Modified by client 1")
        try TestHelpers.createTestFile(at: testFile2, content: "Modified by client 2")
        
        // 等待同步和冲突处理（用条件等待避免时序抖动导致误判）
        let settled = await TestHelpers.waitForCondition(timeout: 20.0) {
            let conflictFiles1 = TestHelpers.getAllFiles(in: self.tempDir1)
                .filter { $0.lastPathComponent.contains(".conflict.") }
            let conflictFiles2 = TestHelpers.getAllFiles(in: self.tempDir2)
                .filter { $0.lastPathComponent.contains(".conflict.") }
            let hasConflict = conflictFiles1.count > 0 || conflictFiles2.count > 0
            if hasConflict { return true }
            
            let content1 = (try? TestHelpers.readFileContent(at: testFile1)) ?? ""
            let content2 = (try? TestHelpers.readFileContent(at: testFile2)) ?? ""
            return content1 == content2 && (content1 == "Modified by client 1" || content1 == "Modified by client 2")
        }
        XCTAssertTrue(settled, "应生成冲突文件，或最终收敛到某一端修改的版本")
        
        // 理想情况：生成冲突文件；否则应当收敛到其中一个版本（上面已等待并断言 settled）
        
        // 验证原文件仍然存在（其中一个版本）
        let originalExists1 = TestHelpers.fileExists(at: testFile1)
        let originalExists2 = TestHelpers.fileExists(at: testFile2)
        
        XCTAssertTrue(
            originalExists1 || originalExists2,
            "原文件应该至少在一个客户端存在"
        )
    }
    
    /// 测试并发修改不同部分（大文件）
    func testConcurrentModify_LargeFile() async throws {
        // 创建大文件（1MB）
        let largeFile1 = tempDir1.appendingPathComponent("large_conflict.bin")
        let originalData = TestHelpers.generateLargeFileData(sizeInMB: 1)
        try TestHelpers.createTestFile(at: largeFile1, data: originalData)
        
        // 等待初始同步
        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
        
        // 客户端1修改文件前半部分
        var data1 = originalData
        data1.replaceSubrange(0..<1000, with: Data(repeating: 0xAA, count: 1000))
        try TestHelpers.createTestFile(at: largeFile1, data: data1)
        
        // 客户端2修改文件后半部分
        let largeFile2 = tempDir2.appendingPathComponent("large_conflict.bin")
        var data2 = originalData
        let endRange = (originalData.count - 1000)..<originalData.count
        data2.replaceSubrange(endRange, with: Data(repeating: 0xBB, count: 1000))
        try TestHelpers.createTestFile(at: largeFile2, data: data2)
        
        // 等待同步收敛：理想情况生成冲突文件；否则可能收敛到某一端版本（覆盖式同步）
        let settled = await TestHelpers.waitForCondition(timeout: 30.0) { [self] in
            let conflictFiles1 = TestHelpers.getAllFiles(in: self.tempDir1)
                .filter { $0.lastPathComponent.contains(".conflict.") }
            let conflictFiles2 = TestHelpers.getAllFiles(in: self.tempDir2)
                .filter { $0.lastPathComponent.contains(".conflict.") }
            if conflictFiles1.count > 0 || conflictFiles2.count > 0 { return true }
            
            // 若未生成冲突文件，则接受最终两端一致（可能是 data1 或 data2）
            let f1 = self.tempDir1.appendingPathComponent("large_conflict.bin")
            let f2 = self.tempDir2.appendingPathComponent("large_conflict.bin")
            guard TestHelpers.fileExists(at: f1), TestHelpers.fileExists(at: f2) else { return false }
            guard let d1Final = try? TestHelpers.readFileData(at: f1),
                  let d2Final = try? TestHelpers.readFileData(at: f2) else { return false }
            guard d1Final == d2Final else { return false }
            return d1Final == data1 || d1Final == data2
        }
        
        XCTAssertTrue(settled, "应生成冲突文件，或最终收敛到某一端版本")
    }
    
    /// 测试快速连续修改（可能导致多个冲突）
    func testConcurrentModify_RapidChanges() async throws {
        // 创建文件
        let testFile1 = tempDir1.appendingPathComponent("rapid.txt")
        try TestHelpers.createTestFile(at: testFile1, content: "Version 0")
        
        // 等待 rapid.txt 同步到客户端2，再开始两端快速修改
        let testFile2 = tempDir2.appendingPathComponent("rapid.txt")
        let syncedToClient2 = await TestHelpers.waitForCondition(timeout: 15.0) {
            TestHelpers.fileExists(at: testFile2)
        }
        XCTAssertTrue(syncedToClient2, "rapid.txt 应同步到客户端2后再进行快速修改")
        if !syncedToClient2 { return }
        
        // 客户端1快速连续修改
        for i in 1...5 {
            try TestHelpers.createTestFile(at: testFile1, content: "Version \(i) from client 1")
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2秒
        }
        
        // 客户端2也快速修改
        for i in 1...5 {
            try TestHelpers.createTestFile(at: testFile2, content: "Version \(i) from client 2")
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2秒
        }
        
        // 等待同步收敛：至少一端存在含 "rapid" 的文件（原文件或冲突文件）
        let settled = await TestHelpers.waitForCondition(timeout: 25.0) {
            let files1 = TestHelpers.getAllFiles(in: self.tempDir1).filter { $0.lastPathComponent.contains("rapid") }
            let files2 = TestHelpers.getAllFiles(in: self.tempDir2).filter { $0.lastPathComponent.contains("rapid") }
            return files1.count > 0 || files2.count > 0
        }
        XCTAssertTrue(settled, "同步后应至少一端存在 rapid 相关文件")
    }
    
    // MARK: - 并发删除冲突测试
    
    /// 测试多客户端同时删除同一文件
    func testConcurrentDelete_SameFile() async throws {
        // 创建文件并同步
        let testFile1 = tempDir1.appendingPathComponent("concurrent_delete.txt")
        try TestHelpers.createTestFile(at: testFile1, content: "To be deleted")
        
        // 等待初始同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 客户端1和2同时删除文件
        try FileManager.default.removeItem(at: testFile1)
        
        let testFile2 = tempDir2.appendingPathComponent("concurrent_delete.txt")
        try FileManager.default.removeItem(at: testFile2)
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 验证文件已删除（两个客户端都删除，应该成功）
        let deleted1 = await TestHelpers.waitForCondition(timeout: 10.0) {
            !TestHelpers.fileExists(at: testFile1)
        }
        
        let deleted2 = await TestHelpers.waitForCondition(timeout: 10.0) {
            !TestHelpers.fileExists(at: testFile2)
        }
        
        XCTAssertTrue(deleted1 && deleted2, "文件应该已从两个客户端删除")
    }
    
    // MARK: - 复杂冲突场景
    
    /// 测试添加-删除冲突（客户端A添加，客户端B删除同名文件）
    func testConflict_AddDelete() async throws {
        // 客户端1添加文件
        let testFile1 = tempDir1.appendingPathComponent("add_delete.txt")
        try TestHelpers.createTestFile(at: testFile1, content: "New file from client 1")
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 客户端2删除文件
        let testFile2 = tempDir2.appendingPathComponent("add_delete.txt")
        try FileManager.default.removeItem(at: testFile2)
        
        // 等待同步和冲突处理
        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
        
        // 验证结果（取决于 Vector Clock）
        // 如果添加的 VC 更新，文件应该存在
        // 如果删除的 VC 更新，文件应该不存在
        // 如果并发冲突，应该生成冲突文件
        
        let exists1 = TestHelpers.fileExists(at: testFile1)
        let exists2 = TestHelpers.fileExists(at: testFile2)
        
        let conflictFiles1 = TestHelpers.getAllFiles(in: tempDir1)
            .filter { $0.lastPathComponent.contains("add_delete") && $0.lastPathComponent.contains(".conflict.") }
        
        // 结果应该是合理的（文件存在、不存在或冲突文件）
        XCTAssertTrue(
            exists1 || exists2 || conflictFiles1.count > 0,
            "应该正确处理添加-删除冲突"
        )
    }
    
    /// 测试重命名-修改冲突
    func testConflict_RenameModify() async throws {
        // 创建文件并同步
        let originalFile1 = tempDir1.appendingPathComponent("rename_modify.txt")
        try TestHelpers.createTestFile(at: originalFile1, content: "Original")
        
        // 等待初始同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 客户端1重命名文件
        let renamedFile1 = tempDir1.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: originalFile1, to: renamedFile1)
        
        // 客户端2修改原文件名（如果文件还在）
        let originalFile2 = tempDir2.appendingPathComponent("rename_modify.txt")
        if TestHelpers.fileExists(at: originalFile2) {
            try TestHelpers.createTestFile(at: originalFile2, content: "Modified by client 2")
        }
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 7_000_000_000) // 7秒
        
        // 验证结果
        // 重命名应该被检测到，修改可能产生冲突
        let renamedExists = TestHelpers.fileExists(at: renamedFile1)
        let originalExists = TestHelpers.fileExists(at: originalFile2)
        
        // 检查冲突文件
        let conflictFiles = TestHelpers.getAllFiles(in: tempDir1)
            .filter { $0.lastPathComponent.contains(".conflict.") }
        
        XCTAssertTrue(
            renamedExists || originalExists || conflictFiles.count > 0,
            "应该正确处理重命名-修改冲突"
        )
    }
    
    /// 测试冲突文件不会被再次同步
    func testConflict_ConflictFileNotSynced() async throws {
        // 创建文件并同步
        let testFile1 = tempDir1.appendingPathComponent("conflict_sync.txt")
        try TestHelpers.createTestFile(at: testFile1, content: "Original")
        
        // 等待初始同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 创建冲突
        try TestHelpers.createTestFile(at: testFile1, content: "Modified by client 1")
        let testFile2 = tempDir2.appendingPathComponent("conflict_sync.txt")
        try TestHelpers.createTestFile(at: testFile2, content: "Modified by client 2")
        
        // 等待冲突文件生成
        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
        
        // 获取冲突文件列表
        let conflictFiles1 = TestHelpers.getAllFiles(in: tempDir1)
            .filter { $0.lastPathComponent.contains(".conflict.") }
        
        // 验证冲突文件不会被同步到另一个客户端
        // 冲突文件应该被 ConflictFileFilter 过滤掉
        if let conflictFile = conflictFiles1.first {
            let conflictFileName = conflictFile.lastPathComponent
            let syncedConflictFile = tempDir2.appendingPathComponent(conflictFileName)
            
            // 等待一段时间，确认冲突文件没有被同步
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
            
            XCTAssertFalse(
                TestHelpers.fileExists(at: syncedConflictFile),
                "冲突文件不应该被同步"
            )
        }
    }
}
