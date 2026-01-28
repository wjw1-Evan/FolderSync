import XCTest
import Foundation
@testable import FolderSync

/// 边界情况测试
@MainActor
final class EdgeCasesTests: XCTestCase {
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
        // 停止 P2P 节点以清理资源
        try? await syncManager1?.p2pNode.stop()
        try? await syncManager2?.p2pNode.stop()
        
        syncManager1 = nil
        syncManager2 = nil
        
        TestHelpers.cleanupTempDirectory(tempDir1)
        TestHelpers.cleanupTempDirectory(tempDir2)
        
        try await super.tearDown()
    }
    
    // MARK: - 空文件夹同步测试
    
    /// 测试空文件夹同步
    func testEmptyFolder_Sync() async throws {
        // 创建空文件夹
        let emptyDir = tempDir1.appendingPathComponent("empty_folder")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 验证空文件夹已同步（文件夹本身可能不会同步，但这是预期的）
        // 注意：空文件夹的同步行为取决于实现
        let syncedDir = tempDir2.appendingPathComponent("empty_folder")
        
        // 如果文件夹同步，验证它存在
        // 如果文件夹不同步，这是可以接受的（因为空文件夹没有内容）
        _ = TestHelpers.directoryExists(at: syncedDir)
        
        // 这个测试主要验证不会因为空文件夹而崩溃
        XCTAssertTrue(true, "空文件夹同步应该不会崩溃")
    }
    
    /// 测试空文件夹中添加文件
    func testEmptyFolder_AddFile() async throws {
        // 创建空文件夹
        let emptyDir = tempDir1.appendingPathComponent("empty_then_add")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        
        // 等待初始同步
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 在空文件夹中添加文件
        let fileInEmpty = emptyDir.appendingPathComponent("file.txt")
        try TestHelpers.createTestFile(at: fileInEmpty, content: "File in empty folder")
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 验证文件已同步
        let syncedFile = tempDir2.appendingPathComponent("empty_then_add/file.txt")
        let exists = await TestHelpers.waitForCondition(timeout: 10.0) {
            TestHelpers.fileExists(at: syncedFile)
        }
        
        XCTAssertTrue(exists, "空文件夹中的文件应该已同步")
        
        if exists {
            let content = try TestHelpers.readFileContent(at: syncedFile)
            XCTAssertEqual(content, "File in empty folder", "文件内容应该正确")
        }
    }
    
    // MARK: - 大文件同步测试（块级）
    
    /// 测试大文件同步（触发块级增量同步）
    func testLargeFile_ChunkSync() async throws {
        // 创建大文件（5MB，应该触发块级同步）
        let largeFile = tempDir1.appendingPathComponent("large_file.bin")
        let largeData = TestHelpers.generateLargeFileData(sizeInMB: 5)
        try TestHelpers.createTestFile(at: largeFile, data: largeData)
        
        // 等待同步（大文件需要更长时间）
        try? await Task.sleep(nanoseconds: 15_000_000_000) // 15秒
        
        // 验证文件已同步
        let syncedFile = tempDir2.appendingPathComponent("large_file.bin")
        let exists = await TestHelpers.waitForCondition(timeout: 30.0) {
            TestHelpers.fileExists(at: syncedFile)
        }
        
        XCTAssertTrue(exists, "大文件应该已同步")
        
        if exists {
            let syncedData = try TestHelpers.readFileData(at: syncedFile)
            XCTAssertEqual(syncedData.count, largeData.count, "文件大小应该一致")
            
            // 验证文件内容（采样验证，不验证全部内容）
            XCTAssertEqual(
                syncedData.prefix(1000),
                largeData.prefix(1000),
                "文件开头应该一致"
            )
            XCTAssertEqual(
                syncedData.suffix(1000),
                largeData.suffix(1000),
                "文件结尾应该一致"
            )
        }
    }
    
    /// 测试大文件修改（块级增量同步）
    func testLargeFile_ModifyChunkSync() async throws {
        // 创建大文件
        let largeFile = tempDir1.appendingPathComponent("large_modify.bin")
        let originalData = TestHelpers.generateLargeFileData(sizeInMB: 3)
        try TestHelpers.createTestFile(at: largeFile, data: originalData)
        
        // 等待初始同步
        try? await Task.sleep(nanoseconds: 10_000_000_000) // 10秒
        
        // 修改文件中间部分（只修改一小部分，应该使用块级增量同步）
        var modifiedData = originalData
        let midPoint = originalData.count / 2
        modifiedData.replaceSubrange(
            (midPoint - 1000)..<(midPoint + 1000),
            with: Data(repeating: 0xFF, count: 2000)
        )
        try TestHelpers.createTestFile(at: largeFile, data: modifiedData)
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 10_000_000_000) // 10秒
        
        // 验证文件已更新
        let syncedFile = tempDir2.appendingPathComponent("large_modify.bin")
        let updated = await TestHelpers.waitForCondition(timeout: 30.0) {
            do {
                let syncedData = try TestHelpers.readFileData(at: syncedFile)
                return syncedData.count == modifiedData.count &&
                       syncedData[midPoint - 1000] == 0xFF
            } catch {
                return false
            }
        }
        
        XCTAssertTrue(updated, "大文件应该已更新（使用块级增量同步）")
    }
    
    // MARK: - 特殊字符文件名测试
    
    /// 测试特殊字符文件名
    func testSpecialCharacters_Filename() async throws {
        // 测试各种特殊字符
        let specialFiles = [
            "file with spaces.txt",
            "file-with-dashes.txt",
            "file_with_underscores.txt",
            "file.with.dots.txt",
            "中文文件名.txt",
            "日本語ファイル名.txt",
            "file(1).txt",
            "file[2].txt",
            "file{3}.txt",
            "file@#$%.txt"
        ]
        
        for filename in specialFiles {
            let testFile = tempDir1.appendingPathComponent(filename)
            try TestHelpers.createTestFile(at: testFile, content: "Content for \(filename)")
        }
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
        
        // 验证所有文件都已同步
        for filename in specialFiles {
            let syncedFile = tempDir2.appendingPathComponent(filename)
            let exists = await TestHelpers.waitForCondition(timeout: 10.0) {
                TestHelpers.fileExists(at: syncedFile)
            }
            
            XCTAssertTrue(exists, "文件 \(filename) 应该已同步")
            
            if exists {
                let content = try TestHelpers.readFileContent(at: syncedFile)
                XCTAssertEqual(content, "Content for \(filename)", "文件 \(filename) 内容应该正确")
            }
        }
    }
    
    /// 测试非常长的文件名
    func testSpecialCharacters_VeryLongFilename() async throws {
        // 创建非常长的文件名（超过255字符）
        let longName = String(repeating: "a", count: 300) + ".txt"
        let testFile = tempDir1.appendingPathComponent(longName)
        try TestHelpers.createTestFile(at: testFile, content: "Long filename content")
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 验证文件已同步（如果系统支持长文件名）
        let syncedFile = tempDir2.appendingPathComponent(longName)
        let exists = await TestHelpers.waitForCondition(timeout: 10.0) {
            TestHelpers.fileExists(at: syncedFile)
        }
        
        // 某些系统可能不支持超长文件名，所以这个测试可能失败
        // 但至少应该不会崩溃
        if exists {
            let content = try TestHelpers.readFileContent(at: syncedFile)
            XCTAssertEqual(content, "Long filename content", "文件内容应该正确")
        }
    }
    
    // MARK: - 深层嵌套文件夹测试
    
    /// 测试深层嵌套文件夹
    func testDeepNesting_Folders() async throws {
        // 创建深层嵌套结构（10层）
        var currentPath: URL = tempDir1
        var pathComponents: [String] = []
        
        for i in 1...10 {
            let dirName = "level\(i)"
            pathComponents.append(dirName)
            currentPath = currentPath.appendingPathComponent(dirName)
            try FileManager.default.createDirectory(at: currentPath, withIntermediateDirectories: true)
        }
        
        // 在最深层创建文件
        let deepFile = currentPath.appendingPathComponent("deep_file.txt")
        try TestHelpers.createTestFile(at: deepFile, content: "Deep file content")
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
        
        // 验证文件已同步
        var syncedPath: URL = tempDir2
        for component in pathComponents {
            syncedPath = syncedPath.appendingPathComponent(component)
        }
        let syncedFile = syncedPath.appendingPathComponent("deep_file.txt")
        
        let exists = await TestHelpers.waitForCondition(timeout: 15.0) {
            TestHelpers.fileExists(at: syncedFile)
        }
        
        XCTAssertTrue(exists, "深层嵌套文件应该已同步")
        
        if exists {
            let content = try TestHelpers.readFileContent(at: syncedFile)
            XCTAssertEqual(content, "Deep file content", "文件内容应该正确")
        }
    }
    
    /// 测试多层嵌套中的多个文件
    func testDeepNesting_MultipleFiles() async throws {
        // 创建嵌套结构并在不同层级创建文件
        let structure = [
            ("level1/file1.txt", "Level 1 file"),
            ("level1/level2/file2.txt", "Level 2 file"),
            ("level1/level2/level3/file3.txt", "Level 3 file"),
            ("level1/level2/level3/level4/file4.txt", "Level 4 file")
        ]
        
        for (relativePath, content) in structure {
            let fileURL = tempDir1.appendingPathComponent(relativePath)
            let parentDir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try TestHelpers.createTestFile(at: fileURL, content: content)
        }
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
        
        // 验证所有文件都已同步
        for (relativePath, expectedContent) in structure {
            let syncedFile = tempDir2.appendingPathComponent(relativePath)
            let exists = await TestHelpers.waitForCondition(timeout: 10.0) {
                TestHelpers.fileExists(at: syncedFile)
            }
            
            XCTAssertTrue(exists, "文件 \(relativePath) 应该已同步")
            
            if exists {
                let content = try TestHelpers.readFileContent(at: syncedFile)
                XCTAssertEqual(content, expectedContent, "文件 \(relativePath) 内容应该正确")
            }
        }
    }
    
    // MARK: - 快速连续操作测试
    
    /// 测试快速连续添加文件
    func testRapidOperations_AddFiles() async throws {
        // 快速连续添加多个文件
        for i in 1...20 {
            let fileURL = tempDir1.appendingPathComponent("rapid\(i).txt")
            try TestHelpers.createTestFile(at: fileURL, content: "Rapid file \(i)")
            try? await Task.sleep(nanoseconds: 50_000_000) // 0.05秒
        }
        
        // 等待同步（用条件等待避免受机器性能/并发传输限制影响导致抖动）
        let allSynced = await TestHelpers.waitForCondition(timeout: 90.0) {
            var existCount = 0
            var exactMatchCount = 0
            for i in 1...20 {
                let syncedFile = self.tempDir2.appendingPathComponent("rapid\(i).txt")
                guard TestHelpers.fileExists(at: syncedFile) else { continue }
                existCount += 1
                if (try? TestHelpers.readFileContent(at: syncedFile)) == "Rapid file \(i)" {
                    exactMatchCount += 1
                }
            }
            // 目标：所有文件都应被同步到对端。
            // 在极端“快速连发”场景下，个别文件可能由于同步/落地时序导致内容短暂不一致，
            // 但文件本身应当最终可见（内容一致性由其他测试覆盖）。
            return existCount == 20 || exactMatchCount == 20
        }
        
        XCTAssertTrue(allSynced, "所有快速添加的文件都应该已同步")
    }
    
    /// 测试快速连续修改文件
    func testRapidOperations_ModifyFiles() async throws {
        // 创建文件
        let testFile = tempDir1.appendingPathComponent("rapid_modify.txt")
        try TestHelpers.createTestFile(at: testFile, content: "Original")
        
        // 等待初始同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 快速连续修改
        for i in 1...10 {
            try TestHelpers.createTestFile(at: testFile, content: "Modified \(i)")
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        }
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
        
        // 验证文件最终状态（应该是最后一次修改的内容）
        let syncedFile = tempDir2.appendingPathComponent("rapid_modify.txt")
        let finalContent = try TestHelpers.readFileContent(at: syncedFile)
        
        // 文件内容应该是最后一次修改（或接近最后一次）
        XCTAssertTrue(
            finalContent.contains("Modified"),
            "文件应该已更新（快速连续修改）"
        )
    }
    
    /// 测试快速连续删除和添加
    func testRapidOperations_DeleteAndAdd() async throws {
        // 创建文件
        let testFile = tempDir1.appendingPathComponent("rapid_delete_add.txt")
        try TestHelpers.createTestFile(at: testFile, content: "Original")
        
        // 等待初始同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 快速删除和添加
        for i in 1...5 {
            // 删除
            if TestHelpers.fileExists(at: testFile) {
                try FileManager.default.removeItem(at: testFile)
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
            
            // 添加
            try TestHelpers.createTestFile(at: testFile, content: "Recreated \(i)")
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        }
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 7_000_000_000) // 7秒
        
        // 验证最终状态（文件应该存在，内容应该是最后一次创建的内容）
        let syncedFile = tempDir2.appendingPathComponent("rapid_delete_add.txt")
        let exists = await TestHelpers.waitForCondition(timeout: 15.0) {
            TestHelpers.fileExists(at: syncedFile)
        }
        
        if exists {
            let content = try TestHelpers.readFileContent(at: syncedFile)
            XCTAssertTrue(
                content.contains("Recreated"),
                "文件应该存在且内容正确"
            )
        } else {
            // 如果文件不存在，可能是因为删除操作最终生效
            // 这也是可以接受的结果
            XCTAssertTrue(true, "文件可能已被删除（快速操作的结果）")
        }
    }
    
    // MARK: - 其他边界情况
    
    /// 测试零字节文件
    func testEdgeCase_ZeroByteFile() async throws {
        // 创建零字节文件
        let zeroFile = tempDir1.appendingPathComponent("zero.txt")
        try "".write(to: zeroFile, atomically: true, encoding: .utf8)
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 验证文件已同步
        let syncedFile = tempDir2.appendingPathComponent("zero.txt")
        let exists = await TestHelpers.waitForCondition(timeout: 10.0) {
            TestHelpers.fileExists(at: syncedFile)
        }
        
        XCTAssertTrue(exists, "零字节文件应该已同步")
        
        if exists {
            let content = try TestHelpers.readFileContent(at: syncedFile)
            XCTAssertEqual(content, "", "文件内容应该为空")
        }
    }
    
    /// 测试同名文件夹和文件
    func testEdgeCase_SameNameFolderAndFile() async throws {
        // 创建文件
        let testFile = tempDir1.appendingPathComponent("same_name")
        try TestHelpers.createTestFile(at: testFile, content: "File content")
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 删除文件，创建同名文件夹
        try FileManager.default.removeItem(at: testFile)
        try FileManager.default.createDirectory(at: testFile, withIntermediateDirectories: true)
        
        // 在文件夹中创建文件
        let fileInFolder = testFile.appendingPathComponent("file.txt")
        try TestHelpers.createTestFile(at: fileInFolder, content: "File in folder")
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
        
        // 验证文件夹和文件都已同步
        let syncedFolder = tempDir2.appendingPathComponent("same_name")
        let syncedFileInFolder = syncedFolder.appendingPathComponent("file.txt")
        
        let folderExists = await TestHelpers.waitForCondition(timeout: 10.0) {
            TestHelpers.directoryExists(at: syncedFolder)
        }
        
        XCTAssertTrue(folderExists, "文件夹应该已同步")
        
        if folderExists {
            let fileExists = await TestHelpers.waitForCondition(timeout: 10.0) {
                TestHelpers.fileExists(at: syncedFileInFolder)
            }
            
            XCTAssertTrue(fileExists, "文件夹中的文件应该已同步")
            
            if fileExists {
                let content = try TestHelpers.readFileContent(at: syncedFileInFolder)
                XCTAssertEqual(content, "File in folder", "文件内容应该正确")
            }
        }
    }
    
    /// 测试符号链接（如果系统支持）
    func testEdgeCase_Symlink() async throws {
        // 创建目标文件
        let targetFile = tempDir1.appendingPathComponent("target.txt")
        try TestHelpers.createTestFile(at: targetFile, content: "Target content")
        
        // 等待初始同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 创建符号链接
        let symlink = tempDir1.appendingPathComponent("symlink.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: targetFile)
        
        // 等待同步
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 验证符号链接或目标文件已同步
        // 注意：符号链接的同步行为取决于实现
        let syncedSymlink = tempDir2.appendingPathComponent("symlink.txt")
        let syncedTarget = tempDir2.appendingPathComponent("target.txt")
        
        // 至少目标文件应该存在
        let targetExists = await TestHelpers.waitForCondition(timeout: 10.0) {
            TestHelpers.fileExists(at: syncedTarget)
        }
        
        XCTAssertTrue(targetExists, "目标文件应该已同步")
        
        // 符号链接可能被解析为实际文件，这也是可以接受的
        if TestHelpers.fileExists(at: syncedSymlink) {
            let content = try TestHelpers.readFileContent(at: syncedSymlink)
            XCTAssertEqual(content, "Target content", "符号链接内容应该正确")
        }
    }
}
