import XCTest
import Foundation
@testable import FolderSync

/// 重新上线测试
@MainActor
final class ReconnectSyncTests: TwoClientTestCase {
    
    /// 双节点需更长时间完成发现与注册
    override var folderDiscoveryWait: UInt64 { TestDuration.longSync }
    
    // MARK: - 重新上线后同步测试
    
    /// 测试客户端离线期间的操作在上线后同步
    func testReconnect_SyncOfflineOperations() async throws {
        // 模拟客户端2离线
        try await simulateClient2Offline()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 客户端1执行多个操作
        let operations = [
            ("add1.txt", "Added file 1"),
            ("add2.txt", "Added file 2"),
            ("modify.txt", "Modified content")
        ]
        
        // 先创建 modify.txt
        let modifyFile = tempDir1.appendingPathComponent("modify.txt")
        try TestHelpers.createTestFile(at: modifyFile, content: "Original")
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 添加和修改文件
        for (filename, content) in operations {
            let fileURL = tempDir1.appendingPathComponent(filename)
            try TestHelpers.createTestFile(at: fileURL, content: content)
        }
        
        // 删除一个文件
        let deleteFile = tempDir1.appendingPathComponent("delete.txt")
        try TestHelpers.createTestFile(at: deleteFile, content: "To delete")
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        try FileManager.default.removeItem(at: deleteFile)
        
        // 等待客户端1处理
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 客户端2上线
        try await simulateClient2Online()
        await waitDiscoveryAndTriggerSyncFromClient1()
        
        // 验证所有操作都已同步
        for (filename, expectedContent) in operations {
            let syncedFile = tempDir2.appendingPathComponent(filename)
            let exists = await TestHelpers.waitForCondition(timeout: 10.0) {
                TestHelpers.fileExists(at: syncedFile)
            }
            
            XCTAssertTrue(exists, "文件 \(filename) 应该已同步")
            
            if exists {
                let content = try TestHelpers.readFileContent(at: syncedFile)
                XCTAssertEqual(content, expectedContent, "文件 \(filename) 内容应该正确")
            }
        }
        
        // 验证删除的文件不存在
        let syncedDelete = tempDir2.appendingPathComponent("delete.txt")
        let deleted = await TestHelpers.waitForCondition(timeout: 10.0) {
            !TestHelpers.fileExists(at: syncedDelete)
        }
        XCTAssertTrue(deleted, "删除的文件应该不存在")
    }
    
    /// 测试删除记录传播
    func testReconnect_DeletionRecordPropagation() async throws {
        // 创建文件并同步
        let testFile = tempDir1.appendingPathComponent("deletion_test.txt")
        try TestHelpers.createTestFile(at: testFile, content: "To be deleted")
        
        // 等待初始同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 验证文件已同步
        let syncedFile = tempDir2.appendingPathComponent("deletion_test.txt")
        XCTAssertTrue(TestHelpers.fileExists(at: syncedFile), "文件应该已同步")
        
        // 模拟客户端2离线
        try await simulateClient2Offline()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 客户端1删除文件
        try FileManager.default.removeItem(at: testFile)
        
        // 等待客户端1创建删除记录
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 验证客户端1有删除记录
        let deletedPaths = syncManager1.deletedPaths(for: syncID)
        XCTAssertTrue(deletedPaths.contains("deletion_test.txt"), "客户端1应该有删除记录")
        
        // 客户端2上线
        try await simulateClient2Online()
        await waitDiscoveryAndTriggerSyncFromClient1()
        
        // 等待删除记录传播和文件删除
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 验证文件已删除
        let deleted = await TestHelpers.waitForCondition(timeout: 15.0) {
            !TestHelpers.fileExists(at: syncedFile)
        }
        
        XCTAssertTrue(deleted, "文件应该已删除")
        
        // 验证客户端2也有删除记录（等待同步应用删除记录，本方法已在 MainActor）
        var hasDeletionRecord = false
        let deletionRecordDeadline = Date().addingTimeInterval(10.0)
        while Date() < deletionRecordDeadline {
            if syncManager2.deletedPaths(for: syncID).contains("deletion_test.txt") {
                hasDeletionRecord = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        }
        XCTAssertTrue(hasDeletionRecord, "客户端2应该有删除记录")
    }
    
    /// 测试 Vector Clock 合并
    func testReconnect_VectorClockMerge() async throws {
        // 创建文件并同步
        let testFile = tempDir1.appendingPathComponent("vc_test.txt")
        try TestHelpers.createTestFile(at: testFile, content: "Original")
        
        // 等待初始同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 模拟客户端2离线
        try await simulateClient2Offline()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 客户端1修改文件（更新 Vector Clock）
        try TestHelpers.createTestFile(at: testFile, content: "Modified by client 1")
        
        // 等待客户端1处理
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 客户端2上线
        try await simulateClient2Online()
        await waitDiscoveryAndTriggerSyncFromClient1()
        
        // 验证文件已更新
        let syncedFile = tempDir2.appendingPathComponent("vc_test.txt")
        let updated = await TestHelpers.waitForCondition(timeout: 15.0) {
            do {
                let content = try TestHelpers.readFileContent(at: syncedFile)
                return content == "Modified by client 1"
            } catch {
                return false
            }
        }
        
        XCTAssertTrue(updated, "文件应该已更新（Vector Clock 已合并）")
        
        // 验证 Vector Clock 已正确合并
        // 注意：这里需要访问 VectorClockManager 来验证，但为了简化测试，我们通过文件内容来间接验证
    }
    
    /// 测试多次离线上线
    func testReconnect_MultipleReconnects() async throws {
        // 第一次离线
        try await simulateClient2Offline()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 客户端1添加文件1
        let file1 = tempDir1.appendingPathComponent("reconnect1.txt")
        try TestHelpers.createTestFile(at: file1, content: "After first disconnect")
        
        // 客户端2上线
        try await simulateClient2Online()
        await waitDiscoveryAndTriggerSyncFromClient1()
        
        // 验证文件1已同步
        let syncedFile1 = tempDir2.appendingPathComponent("reconnect1.txt")
        let exists1 = await TestHelpers.waitForCondition(timeout: 10.0) {
            TestHelpers.fileExists(at: syncedFile1)
        }
        XCTAssertTrue(exists1, "文件1应该已同步")
        
        // 第二次离线
        try await simulateClient2Offline()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 客户端1添加文件2
        let file2 = tempDir1.appendingPathComponent("reconnect2.txt")
        try TestHelpers.createTestFile(at: file2, content: "After second disconnect")
        
        // 客户端2上线
        try await simulateClient2Online()
        await waitDiscoveryAndTriggerSyncFromClient1()
        
        // 验证文件2已同步
        let syncedFile2 = tempDir2.appendingPathComponent("reconnect2.txt")
        let exists2 = await TestHelpers.waitForCondition(timeout: 10.0) {
            TestHelpers.fileExists(at: syncedFile2)
        }
        XCTAssertTrue(exists2, "文件2应该已同步")
        
        // 验证两个文件都存在
        XCTAssertTrue(TestHelpers.fileExists(at: syncedFile1), "文件1应该仍然存在")
        XCTAssertTrue(TestHelpers.fileExists(at: syncedFile2), "文件2应该存在")
    }
    
    // MARK: - 网络中断恢复测试
    
    /// 测试同步过程中网络中断，网络恢复后继续同步
    func testNetworkInterruption_DuringSync() async throws {
        // 创建大文件（触发长时间同步）
        let largeFile = tempDir1.appendingPathComponent("large_sync.bin")
        let largeData = TestHelpers.generateLargeFileData(sizeInMB: 1) // 1MB
        try TestHelpers.createTestFile(at: largeFile, data: largeData)
        
        // 开始同步
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 模拟网络中断（客户端2离线）
        try await simulateClient2Offline()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 网络恢复（客户端2上线）
        try await simulateClient2Online()
        await waitDiscoveryAndTriggerSyncFromClient1()
        
        // 验证文件已同步
        let syncedFile = tempDir2.appendingPathComponent("large_sync.bin")
        let exists = await TestHelpers.waitForCondition(timeout: 20.0) {
            TestHelpers.fileExists(at: syncedFile)
        }
        
        XCTAssertTrue(exists, "文件应该已同步（即使网络中断）")
        
        if exists {
            let syncedData = try TestHelpers.readFileData(at: syncedFile)
            XCTAssertEqual(syncedData.count, largeData.count, "文件大小应该一致")
            XCTAssertEqual(syncedData, largeData, "文件内容应该一致")
        }
    }
    
    /// 测试同步完整性验证
    func testReconnect_SyncIntegrity() async throws {
        // 创建多个文件
        let files = [
            ("file1.txt", "Content 1"),
            ("file2.txt", "Content 2"),
            ("file3.txt", "Content 3"),
            ("subdir/file4.txt", "Content 4")
        ]
        
        // 模拟客户端2离线
        try await simulateClient2Offline()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 客户端1创建所有文件
        for (relativePath, content) in files {
            let fileURL = tempDir1.appendingPathComponent(relativePath)
            let parentDir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try TestHelpers.createTestFile(at: fileURL, content: content)
        }
        
        // 等待客户端1处理
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 客户端2上线
        try await simulateClient2Online()
        await waitDiscoveryAndTriggerSyncFromClient1()
        
        // 验证所有文件都已同步（完整性检查）
        var syncedCount = 0
        for (relativePath, expectedContent) in files {
            let syncedFile = tempDir2.appendingPathComponent(relativePath)
            let exists = await TestHelpers.waitForCondition(timeout: 10.0) {
                TestHelpers.fileExists(at: syncedFile)
            }
            
            if exists {
                let content = try TestHelpers.readFileContent(at: syncedFile)
                if content == expectedContent {
                    syncedCount += 1
                }
            }
        }
        
        XCTAssertEqual(syncedCount, files.count, "所有文件都应该已同步且内容正确")
    }
    
    /// 测试离线期间删除后重新创建文件
    func testReconnect_DeleteThenRecreate() async throws {
        // 创建文件并同步
        let testFile = tempDir1.appendingPathComponent("recreate.txt")
        try TestHelpers.createTestFile(at: testFile, content: "Original")
        
        // 等待初始同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 模拟客户端2离线
        try await simulateClient2Offline()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 客户端1删除文件
        try FileManager.default.removeItem(at: testFile)
        
        // 等待删除记录创建
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 客户端1重新创建文件（相同路径，不同内容）
        try TestHelpers.createTestFile(at: testFile, content: "Recreated")
        
        // 等待客户端1处理
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 客户端2上线
        try await simulateClient2Online()
        await waitDiscoveryAndTriggerSyncFromClient1()
        
        // 验证文件已重新创建（新文件，不是旧文件）
        let syncedFile = tempDir2.appendingPathComponent("recreate.txt")
        let exists = await TestHelpers.waitForCondition(timeout: 15.0) {
            TestHelpers.fileExists(at: syncedFile)
        }
        
        XCTAssertTrue(exists, "文件应该已重新创建")
        
        if exists {
            let content = try TestHelpers.readFileContent(at: syncedFile)
            XCTAssertEqual(content, "Recreated", "文件内容应该是重新创建的内容")
        }
    }
    
    /// 测试离线期间的操作顺序
    func testReconnect_OperationOrder() async throws {
        // 模拟客户端2离线
        try await simulateClient2Offline()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 客户端1执行一系列操作
        // 1. 添加文件
        let file1 = tempDir1.appendingPathComponent("order1.txt")
        try TestHelpers.createTestFile(at: file1, content: "File 1")
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
        
        // 2. 修改文件
        try TestHelpers.createTestFile(at: file1, content: "File 1 modified")
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
        
        // 3. 添加另一个文件
        let file2 = tempDir1.appendingPathComponent("order2.txt")
        try TestHelpers.createTestFile(at: file2, content: "File 2")
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
        
        // 4. 删除第一个文件
        try FileManager.default.removeItem(at: file1)
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
        
        // 5. 重命名第二个文件
        let file2Renamed = tempDir1.appendingPathComponent("order2_renamed.txt")
        try FileManager.default.moveItem(at: file2, to: file2Renamed)
        
        // 等待客户端1处理
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 客户端2上线
        try await simulateClient2Online()
        await waitDiscoveryAndTriggerSyncFromClient1()
        
        // 验证最终状态
        // 文件1应该不存在（已删除）
        let syncedFile1 = tempDir2.appendingPathComponent("order1.txt")
        let deleted1 = await TestHelpers.waitForCondition(timeout: 10.0) {
            !TestHelpers.fileExists(at: syncedFile1)
        }
        XCTAssertTrue(deleted1, "文件1应该已删除")
        
        // 文件2应该已重命名
        let syncedFile2Renamed = tempDir2.appendingPathComponent("order2_renamed.txt")
        let renamed = await TestHelpers.waitForCondition(timeout: 10.0) {
            TestHelpers.fileExists(at: syncedFile2Renamed)
        }
        XCTAssertTrue(renamed, "文件2应该已重命名")
        
        if renamed {
            let content = try TestHelpers.readFileContent(at: syncedFile2Renamed)
            XCTAssertEqual(content, "File 2", "重命名后的文件内容应该正确")
        }
        
        // 原文件名不应该存在（等待删除/重命名同步完成）
        let syncedFile2 = tempDir2.appendingPathComponent("order2.txt")
        let order2Gone = await TestHelpers.waitForCondition(timeout: 10.0) {
            !TestHelpers.fileExists(at: syncedFile2)
        }
        XCTAssertTrue(order2Gone, "原文件名不应该存在")
    }
}
