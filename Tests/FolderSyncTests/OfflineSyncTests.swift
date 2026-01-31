import XCTest
import Foundation
@testable import FolderSync

/// 离线场景测试
@MainActor
final class OfflineSyncTests: XCTestCase {
    var tempDir1: URL!
    var tempDir2: URL!
    var syncManager1: SyncManager!
    var syncManager2: SyncManager!
    var syncID: String!
    
    override func setUp() async throws {
        try await super.setUp()
        
        tempDir1 = try TestHelpers.createTempDirectory()
        tempDir2 = try TestHelpers.createTempDirectory()
        syncID = "test\(UUID().uuidString.prefix(8))"
        
        syncManager1 = SyncManager()
        syncManager2 = SyncManager()
        
        // 等待 P2P 节点启动
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 添加文件夹
        let folder1 = TestHelpers.createTestSyncFolder(syncID: syncID, localPath: tempDir1)
        syncManager1.addFolder(folder1)
        
        let folder2 = TestHelpers.createTestSyncFolder(syncID: syncID, localPath: tempDir2)
        syncManager2.addFolder(folder2)
        
        // 等待文件夹添加和发现
        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
    }
    
    override func tearDown() async throws {
        // 停止 P2P 节点以清理资源（stop 可重复调用，已停止时无副作用）
        try? await syncManager1?.p2pNode.stop()
        try? await syncManager2?.p2pNode.stop()
        
        syncManager1 = nil
        syncManager2 = nil
        
        if tempDir1 != nil { TestHelpers.cleanupTempDirectory(tempDir1) }
        if tempDir2 != nil { TestHelpers.cleanupTempDirectory(tempDir2) }
        
        try await super.tearDown()
    }
    
    /// 模拟客户端2离线（通过停止其 P2P 网络服务实现）
    func simulateClient2Offline() async throws {
        try await syncManager2.p2pNode.stop()
    }
    
    /// 模拟客户端2上线（重新启动其 P2P 网络服务）
    func simulateClient2Online() async throws {
        try await syncManager2.p2pNode.start()
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 等待重新发现
    }
    
    // MARK: - 离线添加测试
    
    /// 测试客户端A添加文件，客户端B离线，客户端B上线后同步
    func testOfflineAdd_File() async throws {
        // 模拟客户端2离线
        try await simulateClient2Offline()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 客户端1添加文件
        let testFile = tempDir1.appendingPathComponent("offline_add.txt")
        try TestHelpers.createTestFile(at: testFile, content: "Added while client 2 offline")
        
        // 等待客户端1处理
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 验证客户端2还没有文件
        let syncedFile = tempDir2.appendingPathComponent("offline_add.txt")
        XCTAssertFalse(TestHelpers.fileExists(at: syncedFile), "客户端2离线时不应该有文件")
        
        // 客户端2上线
        try await simulateClient2Online()
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
        
        // 验证文件已同步
        let fileExists = await TestHelpers.waitForCondition(timeout: 15.0) {
            TestHelpers.fileExists(at: syncedFile)
        }
        
        XCTAssertTrue(fileExists, "客户端2上线后应该收到文件")
        
        if fileExists {
            let content = try TestHelpers.readFileContent(at: syncedFile)
            XCTAssertEqual(content, "Added while client 2 offline", "文件内容应该正确")
        }
    }
    
    /// 测试离线期间添加多个文件
    func testOfflineAdd_MultipleFiles() async throws {
        // 模拟客户端2离线
        try await simulateClient2Offline()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 客户端1添加多个文件
        let files = [
            ("file1.txt", "Content 1"),
            ("file2.txt", "Content 2"),
            ("subdir/file3.txt", "Content 3")
        ]
        
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
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
        
        // 验证所有文件都已同步
        for (relativePath, expectedContent) in files {
            let syncedFile = tempDir2.appendingPathComponent(relativePath)
            let exists = await TestHelpers.waitForCondition(timeout: 15.0) {
                TestHelpers.fileExists(at: syncedFile)
            }
            
            XCTAssertTrue(exists, "文件 \(relativePath) 应该已同步")
            
            if exists {
                let content = try TestHelpers.readFileContent(at: syncedFile)
                XCTAssertEqual(content, expectedContent, "文件 \(relativePath) 内容应该正确")
            }
        }
    }
    
    // MARK: - 离线修改测试
    
    /// 测试客户端A修改文件，客户端B离线，客户端B上线后同步
    func testOfflineModify_File() async throws {
        // 先创建文件并同步
        let testFile = tempDir1.appendingPathComponent("offline_modify.txt")
        try TestHelpers.createTestFile(at: testFile, content: "Original content")
        
        // 等待初始同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 验证文件已同步
        let syncedFile = tempDir2.appendingPathComponent("offline_modify.txt")
        XCTAssertTrue(TestHelpers.fileExists(at: syncedFile), "文件应该已同步")
        
        // 模拟客户端2离线
        try await simulateClient2Offline()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 客户端1修改文件
        try TestHelpers.createTestFile(at: testFile, content: "Modified while client 2 offline")
        
        // 等待客户端1处理
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 验证客户端2文件还未更新
        let oldContent = try TestHelpers.readFileContent(at: syncedFile)
        XCTAssertEqual(oldContent, "Original content", "客户端2离线时文件不应该更新")
        
        // 客户端2上线
        try await simulateClient2Online()
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
        
        // 验证文件已更新
        let updated = await TestHelpers.waitForCondition(timeout: 15.0) {
            do {
                let content = try TestHelpers.readFileContent(at: syncedFile)
                return content == "Modified while client 2 offline"
            } catch {
                return false
            }
        }
        
        XCTAssertTrue(updated, "客户端2上线后文件应该已更新")
    }
    
    // MARK: - 离线删除测试
    
    /// 测试客户端A删除文件，客户端B离线，客户端B上线后收到删除记录并删除文件
    func testOfflineDelete_File() async throws {
        // 先创建文件并同步
        let testFile = tempDir1.appendingPathComponent("offline_delete.txt")
        try TestHelpers.createTestFile(at: testFile, content: "To be deleted")
        
        // 等待初始同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 验证文件已同步
        let syncedFile = tempDir2.appendingPathComponent("offline_delete.txt")
        XCTAssertTrue(TestHelpers.fileExists(at: syncedFile), "文件应该已同步")
        
        // 模拟客户端2离线
        try await simulateClient2Offline()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 客户端1删除文件
        try FileManager.default.removeItem(at: testFile)
        
        // 等待客户端1处理
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 验证客户端2文件还存在（因为离线）
        XCTAssertTrue(TestHelpers.fileExists(at: syncedFile), "客户端2离线时文件应该还存在")
        
        // 客户端2上线
        try await simulateClient2Online()
        
        // 等待同步（包括删除记录传播）
        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
        
        // 验证文件已删除
        let deleted = await TestHelpers.waitForCondition(timeout: 15.0) {
            !TestHelpers.fileExists(at: syncedFile)
        }
        
        XCTAssertTrue(deleted, "客户端2上线后应该收到删除记录并删除文件")
    }
    
    /// 测试离线期间删除多个文件
    func testOfflineDelete_MultipleFiles() async throws {
        // 创建多个文件并同步
        let files = [
            "delete1.txt",
            "delete2.txt",
            "subdir/delete3.txt"
        ]
        
        for filename in files {
            let fileURL = tempDir1.appendingPathComponent(filename)
            let parentDir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try TestHelpers.createTestFile(at: fileURL, content: "To be deleted")
        }
        
        // 等待初始同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 模拟客户端2离线
        try await simulateClient2Offline()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 客户端1删除所有文件
        for filename in files {
            let fileURL = tempDir1.appendingPathComponent(filename)
            try FileManager.default.removeItem(at: fileURL)
        }
        
        // 等待客户端1处理
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 客户端2上线
        try await simulateClient2Online()
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
        
        // 验证所有文件都已删除
        for filename in files {
            let syncedFile = tempDir2.appendingPathComponent(filename)
            let deleted = await TestHelpers.waitForCondition(timeout: 15.0) {
                !TestHelpers.fileExists(at: syncedFile)
            }
            
            XCTAssertTrue(deleted, "文件 \(filename) 应该已删除")
        }
    }
    
    // MARK: - 离线复制测试
    
    /// 测试客户端A复制文件，客户端B离线，客户端B上线后同步
    func testOfflineCopy_File() async throws {
        // 创建源文件并同步
        let sourceFile = tempDir1.appendingPathComponent("source.txt")
        try TestHelpers.createTestFile(at: sourceFile, content: "Source content")
        
        // 等待初始同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 模拟客户端2离线
        try await simulateClient2Offline()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 客户端1复制文件
        let destFile = tempDir1.appendingPathComponent("copy.txt")
        try FileManager.default.copyItem(at: sourceFile, to: destFile)
        
        // 等待客户端1处理
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 客户端2上线
        try await simulateClient2Online()
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
        
        // 验证复制文件已同步
        let syncedDest = tempDir2.appendingPathComponent("copy.txt")
        let exists = await TestHelpers.waitForCondition(timeout: 15.0) {
            TestHelpers.fileExists(at: syncedDest)
        }
        
        XCTAssertTrue(exists, "复制文件应该已同步")
        
        if exists {
            let content = try TestHelpers.readFileContent(at: syncedDest)
            XCTAssertEqual(content, "Source content", "复制文件内容应该正确")
        }
    }
    
    // MARK: - 离线重命名测试
    
    /// 测试客户端A重命名文件，客户端B离线，客户端B上线后同步
    func testOfflineRename_File() async throws {
        // 创建文件并同步
        let oldFile = tempDir1.appendingPathComponent("old_name.txt")
        try TestHelpers.createTestFile(at: oldFile, content: "File content")
        
        // 等待初始同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 模拟客户端2离线
        try await simulateClient2Offline()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 客户端1重命名文件
        let newFile = tempDir1.appendingPathComponent("new_name.txt")
        try FileManager.default.moveItem(at: oldFile, to: newFile)
        
        // 等待客户端1处理
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 客户端2上线
        try await simulateClient2Online()
        
        // 等待同步（重命名检测可能需要更长时间）
        try? await Task.sleep(nanoseconds: 7_000_000_000) // 7秒
        
        // 验证文件已重命名
        let syncedOldFile = tempDir2.appendingPathComponent("old_name.txt")
        let syncedNewFile = tempDir2.appendingPathComponent("new_name.txt")
        
        let oldDeleted = await TestHelpers.waitForCondition(timeout: 15.0) {
            !TestHelpers.fileExists(at: syncedOldFile)
        }
        XCTAssertTrue(oldDeleted, "旧文件应该已删除")
        
        let newExists = await TestHelpers.waitForCondition(timeout: 10.0) {
            TestHelpers.fileExists(at: syncedNewFile)
        }
        XCTAssertTrue(newExists, "新文件应该存在")
        
        if newExists {
            let content = try TestHelpers.readFileContent(at: syncedNewFile)
            XCTAssertEqual(content, "File content", "文件内容应该一致")
        }
    }
    
    // MARK: - 多客户端离线测试
    
    /// 测试客户端A操作，客户端B和C都离线，客户端B和C依次上线，验证同步
    func testOffline_MultipleClients() async throws {
        // 创建第三个客户端
        let tempDir3 = try TestHelpers.createTempDirectory()
        var syncManager3: SyncManager? = SyncManager()
        
        func cleanupThirdClient() async {
            try? await syncManager3?.p2pNode.stop()
            syncManager3 = nil
            TestHelpers.cleanupTempDirectory(tempDir3)
        }
        
        do {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
            
            let folder3 = TestHelpers.createTestSyncFolder(syncID: syncID, localPath: tempDir3)
            syncManager3?.addFolder(folder3)
            
            // 等待发现
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
            
            // 模拟客户端2和3离线
            try await simulateClient2Offline()
            try await syncManager3?.p2pNode.stop()
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
            
            // 客户端1添加文件
            let testFile = tempDir1.appendingPathComponent("multi_offline.txt")
            try TestHelpers.createTestFile(at: testFile, content: "Added while clients 2 and 3 offline")
            
            // 等待客户端1处理
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
            
            // 客户端2上线
            try await simulateClient2Online()
            
            // 等待客户端2同步
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
            
            // 验证客户端2已同步
            let syncedFile2 = tempDir2.appendingPathComponent("multi_offline.txt")
            let exists2 = await TestHelpers.waitForCondition(timeout: 10.0) {
                TestHelpers.fileExists(at: syncedFile2)
            }
            XCTAssertTrue(exists2, "客户端2应该已同步")
            
            // 客户端3上线
            try await syncManager3?.p2pNode.start()
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
            
            // 等待客户端3同步
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
            
            // 验证客户端3已同步
            let syncedFile3 = tempDir3.appendingPathComponent("multi_offline.txt")
            let exists3 = await TestHelpers.waitForCondition(timeout: 10.0) {
                TestHelpers.fileExists(at: syncedFile3)
            }
            XCTAssertTrue(exists3, "客户端3应该已同步")
            
            if exists3 {
                let content = try TestHelpers.readFileContent(at: syncedFile3)
                XCTAssertEqual(content, "Added while clients 2 and 3 offline", "文件内容应该正确")
            }
        } catch {
            await cleanupThirdClient()
            throw error
        }
        await cleanupThirdClient()
    }
    
    /// 测试离线期间多个操作
    func testOffline_MultipleOperations() async throws {
        // 模拟客户端2离线
        try await simulateClient2Offline()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 客户端1执行多个操作
        // 1. 添加文件
        let addFile = tempDir1.appendingPathComponent("add.txt")
        try TestHelpers.createTestFile(at: addFile, content: "Added")
        
        // 2. 修改文件（先创建）
        let modifyFile = tempDir1.appendingPathComponent("modify.txt")
        try TestHelpers.createTestFile(at: modifyFile, content: "Original")
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        try TestHelpers.createTestFile(at: modifyFile, content: "Modified")
        
        // 3. 删除文件（先创建）
        let deleteFile = tempDir1.appendingPathComponent("delete.txt")
        try TestHelpers.createTestFile(at: deleteFile, content: "To delete")
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        try FileManager.default.removeItem(at: deleteFile)
        
        // 等待客户端1处理
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 客户端2上线
        try await simulateClient2Online()
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 7_000_000_000) // 7秒
        
        // 验证所有操作都已同步
        // 1. 添加的文件应该存在
        let syncedAdd = tempDir2.appendingPathComponent("add.txt")
        let addExists = await TestHelpers.waitForCondition(timeout: 10.0) {
            TestHelpers.fileExists(at: syncedAdd)
        }
        XCTAssertTrue(addExists, "添加的文件应该存在")
        
        // 2. 修改的文件应该已更新
        let syncedModify = tempDir2.appendingPathComponent("modify.txt")
        let modifyUpdated = await TestHelpers.waitForCondition(timeout: 10.0) {
            do {
                let content = try TestHelpers.readFileContent(at: syncedModify)
                return content == "Modified"
            } catch {
                return false
            }
        }
        XCTAssertTrue(modifyUpdated, "修改的文件应该已更新")
        
        // 3. 删除的文件应该不存在
        let syncedDelete = tempDir2.appendingPathComponent("delete.txt")
        let deleteRemoved = await TestHelpers.waitForCondition(timeout: 10.0) {
            !TestHelpers.fileExists(at: syncedDelete)
        }
        XCTAssertTrue(deleteRemoved, "删除的文件应该不存在")
    }
}
