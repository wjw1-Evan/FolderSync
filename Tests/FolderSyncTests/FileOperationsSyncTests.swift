import Foundation
import XCTest

@testable import FolderSync

/// 文件操作同步测试
final class FileOperationsSyncTests: TwoClientTestCase {

    /// 双节点需更长时间完成发现与注册
    override var folderDiscoveryWait: UInt64 { TestDuration.longSync }

    // MARK: - 添加文件测试

    /// 测试客户端A添加文件，客户端B同步
    func testAddFile_SingleFile() async throws {
        // 客户端1添加文件
        let testFile = tempDir1.appendingPathComponent("newfile.txt")
        try TestHelpers.createTestFile(at: testFile, content: "New file content")

        // 等待 FSEvents 记录与同步
        try await Task.sleep(nanoseconds: 6_000_000_000)  // 6秒

        // 验证文件已同步到客户端2
        let syncedFile = tempDir2.appendingPathComponent("newfile.txt")
        let fileExists = await TestHelpers.waitForCondition(timeout: 28.0) {
            TestHelpers.fileExists(at: syncedFile)
        }

        XCTAssertTrue(fileExists, "文件应该已同步到客户端2")

        if fileExists {
            let content = try TestHelpers.readFileContent(at: syncedFile)
            XCTAssertEqual(content, "New file content", "文件内容应该一致")
        }
    }

    /// 测试多客户端同时添加不同文件
    func testAddFile_MultipleClients() async throws {
        // 客户端1添加文件1
        let file1 = tempDir1.appendingPathComponent("file1.txt")
        try TestHelpers.createTestFile(at: file1, content: "File 1 from client 1")

        // 客户端2添加文件2
        let file2 = tempDir2.appendingPathComponent("file2.txt")
        try TestHelpers.createTestFile(at: file2, content: "File 2 from client 2")

        // 等待 FSEvents 记录与双向同步
        try await Task.sleep(nanoseconds: 8_000_000_000)  // 8秒

        // 验证两个文件都已同步到两个客户端
        let filesToCheck: [(URL?, String, String)] = [
            (tempDir1, "file2.txt", "File 2 from client 2"),
            (tempDir2, "file1.txt", "File 1 from client 1"),
        ]

        for (dir, filename, expectedContent) in filesToCheck {
            guard let dir = dir else { continue }
            let fileURL = dir.appendingPathComponent(filename)
            let exists = await TestHelpers.waitForCondition(timeout: 28.0) {
                TestHelpers.fileExists(at: fileURL)
            }

            XCTAssertTrue(exists, "文件 \(filename) 应该在 \(dir.lastPathComponent) 中存在")

            if exists {
                let content = try TestHelpers.readFileContent(at: fileURL)
                XCTAssertEqual(content, expectedContent, "文件内容应该正确")
            }
        }
    }

    /// 测试添加文件夹及其内容
    func testAddFile_FolderWithContents() async throws {
        // 创建嵌套文件夹结构
        let subDir = tempDir1.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        // 在子文件夹中创建文件
        let file1 = subDir.appendingPathComponent("file1.txt")
        try TestHelpers.createTestFile(at: file1, content: "File 1 in subdir")

        let file2 = subDir.appendingPathComponent("file2.txt")
        try TestHelpers.createTestFile(at: file2, content: "File 2 in subdir")

        // 创建更深层的嵌套
        let deepDir = subDir.appendingPathComponent("deep")
        try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)
        let deepFile = deepDir.appendingPathComponent("deepfile.txt")
        try TestHelpers.createTestFile(at: deepFile, content: "Deep file")

        // 等待 FSEvents 记录与嵌套结构同步
        try await Task.sleep(nanoseconds: 8_000_000_000)  // 8秒

        // 验证文件夹结构已同步：先等待子目录出现，再校验文件
        let syncedSubDir = tempDir2.appendingPathComponent("subdir")
        let subDirSynced = await TestHelpers.waitForCondition(timeout: 28.0) {
            TestHelpers.directoryExists(at: syncedSubDir)
        }
        XCTAssertTrue(subDirSynced, "子文件夹应该已同步")

        let syncedFile1 = syncedSubDir.appendingPathComponent("file1.txt")
        let syncedFile2 = syncedSubDir.appendingPathComponent("file2.txt")
        let syncedDeepDir = syncedSubDir.appendingPathComponent("deep")
        let syncedDeepFile = syncedDeepDir.appendingPathComponent("deepfile.txt")

        let filesToCheck = [
            (syncedFile1, "File 1 in subdir"),
            (syncedFile2, "File 2 in subdir"),
            (syncedDeepFile, "Deep file"),
        ]

        for (fileURL, expectedContent) in filesToCheck {
            let exists = await TestHelpers.waitForCondition(timeout: 28.0) {
                TestHelpers.fileExists(at: fileURL)
            }

            XCTAssertTrue(exists, "文件 \(fileURL.lastPathComponent) 应该存在")

            if exists {
                let content = try TestHelpers.readFileContent(at: fileURL)
                XCTAssertEqual(content, expectedContent, "文件内容应该正确")
            }
        }
    }

    // MARK: - 修改文件测试

    /// 测试客户端A修改文件，客户端B同步
    func testModifyFile_SingleFile() async throws {
        // 先创建文件
        let testFile = tempDir1.appendingPathComponent("modify_test.txt")
        try TestHelpers.createTestFile(at: testFile, content: "Original content")

        // 等待初始同步
        try await Task.sleep(nanoseconds: 6_000_000_000)  // 6秒

        // 修改文件
        try TestHelpers.createTestFile(at: testFile, content: "Modified content")

        // 等待同步并验证文件已更新
        let syncedFile = tempDir2.appendingPathComponent("modify_test.txt")
        let updated = await TestHelpers.waitForCondition(timeout: 28.0) {
            guard let c = try? TestHelpers.readFileContent(at: syncedFile) else { return false }
            return c == "Modified content"
        }
        XCTAssertTrue(updated, "文件内容应该已同步为 Modified content")
        if updated {
            let content = try TestHelpers.readFileContent(at: syncedFile)
            XCTAssertEqual(content, "Modified content", "文件内容应该已更新")
        }
    }

    /// 测试多客户端同时修改不同文件
    func testModifyFile_MultipleClients() async throws {
        // 创建两个文件
        let file1 = tempDir1.appendingPathComponent("modify1.txt")
        try TestHelpers.createTestFile(at: file1, content: "Original 1")

        let file2 = tempDir2.appendingPathComponent("modify2.txt")
        try TestHelpers.createTestFile(at: file2, content: "Original 2")

        // 等待初始同步
        try await Task.sleep(nanoseconds: 6_000_000_000)  // 6秒

        // 客户端1修改文件1
        try TestHelpers.createTestFile(at: file1, content: "Modified 1")

        // 客户端2修改文件2
        try TestHelpers.createTestFile(at: file2, content: "Modified 2")

        // 等待同步并验证两个文件都已更新
        let syncedFile1 = tempDir2.appendingPathComponent("modify1.txt")
        let syncedFile2 = tempDir1.appendingPathComponent("modify2.txt")

        let bothUpdated = await TestHelpers.waitForCondition(timeout: 28.0) {
            guard let c1 = try? TestHelpers.readFileContent(at: syncedFile1),
                let c2 = try? TestHelpers.readFileContent(at: syncedFile2)
            else { return false }
            return c1 == "Modified 1" && c2 == "Modified 2"
        }
        XCTAssertTrue(bothUpdated, "两个文件应已同步为 Modified 1 / Modified 2")

        if bothUpdated {
            let content1 = try TestHelpers.readFileContent(at: syncedFile1)
            XCTAssertEqual(content1, "Modified 1", "文件1应该已更新")

            let content2 = try TestHelpers.readFileContent(at: syncedFile2)
            XCTAssertEqual(content2, "Modified 2", "文件2应该已更新")
        }
    }

    /// 测试大文件修改（触发块级同步）
    func testModifyFile_LargeFile() async throws {
        // 创建大文件（2MB）
        let largeFile = tempDir1.appendingPathComponent("large_file.bin")
        let originalData = TestHelpers.generateLargeFileData(sizeInMB: 2)
        try TestHelpers.createTestFile(at: largeFile, data: originalData)

        // 等待初始同步（大文件需更长时间）
        try await Task.sleep(nanoseconds: 12_000_000_000)  // 12秒

        // 修改文件（只修改一部分）
        var modifiedData = originalData
        modifiedData.replaceSubrange(0..<100, with: Data(repeating: 0xFF, count: 100))
        try TestHelpers.createTestFile(at: largeFile, data: modifiedData)

        // 等待同步并验证文件已更新（大文件需要更长时间）
        let syncedFile = tempDir2.appendingPathComponent("large_file.bin")
        let updated = await TestHelpers.waitForCondition(timeout: 55.0) {
            guard TestHelpers.fileExists(at: syncedFile),
                let data = try? TestHelpers.readFileData(at: syncedFile),
                data.count == modifiedData.count,
                data.prefix(100) == modifiedData.prefix(100)
            else { return false }
            return true
        }
        XCTAssertTrue(updated, "大文件应在对端存在且前100字节为 0xFF")

        if updated {
            let syncedData = try TestHelpers.readFileData(at: syncedFile)
            XCTAssertEqual(syncedData.count, modifiedData.count, "文件大小应该一致")
            XCTAssertEqual(syncedData.prefix(100), modifiedData.prefix(100), "文件前100字节应该已更新")
        }
    }

    // MARK: - 删除文件测试

    /// 测试客户端A删除文件，客户端B同步
    func testDeleteFile_SingleFile() async throws {
        // 先创建文件
        let testFile = tempDir1.appendingPathComponent("delete_test.txt")
        try TestHelpers.createTestFile(at: testFile, content: "To be deleted")

        // 等待初始同步
        try await Task.sleep(nanoseconds: 6_000_000_000)  // 6秒

        // 验证文件已同步到客户端2
        let syncedFile = tempDir2.appendingPathComponent("delete_test.txt")
        let synced = await TestHelpers.waitForCondition(timeout: 28.0) {
            TestHelpers.fileExists(at: syncedFile)
        }
        XCTAssertTrue(synced, "文件应该已同步")

        // 删除文件
        try FileManager.default.removeItem(at: testFile)

        // 等待同步
        try await Task.sleep(nanoseconds: 3_000_000_000)  // 3秒

        // 验证文件已删除
        let fileDeleted = await TestHelpers.waitForCondition(timeout: 10.0) {
            !TestHelpers.fileExists(at: syncedFile)
        }

        XCTAssertTrue(fileDeleted, "文件应该已从客户端2删除")
    }

    /// 测试多客户端删除不同文件
    func testDeleteFile_MultipleClients() async throws {
        // 创建两个文件
        let file1 = tempDir1.appendingPathComponent("delete1.txt")
        try TestHelpers.createTestFile(at: file1, content: "File 1")

        let file2 = tempDir2.appendingPathComponent("delete2.txt")
        try TestHelpers.createTestFile(at: file2, content: "File 2")

        // 等待初始同步
        try await Task.sleep(nanoseconds: 3_000_000_000)  // 3秒

        // 客户端1删除文件1
        try FileManager.default.removeItem(at: file1)

        // 客户端2删除文件2
        try FileManager.default.removeItem(at: file2)

        // 等待同步
        try await Task.sleep(nanoseconds: 5_000_000_000)  // 5秒

        // 验证两个文件都已删除
        let syncedFile1 = tempDir2.appendingPathComponent("delete1.txt")
        let syncedFile2 = tempDir1.appendingPathComponent("delete2.txt")

        let deleted1 = await TestHelpers.waitForCondition(timeout: 10.0) {
            !TestHelpers.fileExists(at: syncedFile1)
        }
        XCTAssertTrue(deleted1, "文件1应该已删除")

        let deleted2 = await TestHelpers.waitForCondition(timeout: 10.0) {
            !TestHelpers.fileExists(at: syncedFile2)
        }
        XCTAssertTrue(deleted2, "文件2应该已删除")
    }

    /// 测试删除文件夹及其内容
    func testDeleteFile_FolderWithContents() async throws {
        // 创建文件夹结构
        let subDir = tempDir1.appendingPathComponent("to_delete")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let file1 = subDir.appendingPathComponent("file1.txt")
        try TestHelpers.createTestFile(at: file1, content: "File 1")

        let file2 = subDir.appendingPathComponent("file2.txt")
        try TestHelpers.createTestFile(at: file2, content: "File 2")

        // 等待初始同步
        try await Task.sleep(nanoseconds: 3_000_000_000)  // 3秒

        // 删除整个文件夹
        try FileManager.default.removeItem(at: subDir)

        // 等待同步
        try await Task.sleep(nanoseconds: 3_000_000_000)  // 3秒

        // 验证文件夹及其内容已删除
        let syncedSubDir = tempDir2.appendingPathComponent("to_delete")
        let deleted = await TestHelpers.waitForCondition(timeout: 10.0) {
            !TestHelpers.directoryExists(at: syncedSubDir)
        }

        XCTAssertTrue(deleted, "文件夹应该已删除")
    }

    // MARK: - 复制文件测试

    /// 测试客户端A复制文件，客户端B同步
    func testCopyFile_SingleFile() async throws {
        // 创建源文件
        let sourceFile = tempDir1.appendingPathComponent("source.txt")
        try TestHelpers.createTestFile(at: sourceFile, content: "Source content")

        // 等待初始同步
        try await Task.sleep(nanoseconds: 6_000_000_000)  // 6秒

        // 复制文件
        let destFile = tempDir1.appendingPathComponent("copy.txt")
        try FileManager.default.copyItem(at: sourceFile, to: destFile)

        // 等待同步
        try await Task.sleep(nanoseconds: 6_000_000_000)  // 6秒

        // 验证两个文件都已同步到客户端2
        let syncedSource = tempDir2.appendingPathComponent("source.txt")
        let syncedDest = tempDir2.appendingPathComponent("copy.txt")

        let bothSynced = await TestHelpers.waitForCondition(timeout: 28.0) {
            TestHelpers.fileExists(at: syncedSource) && TestHelpers.fileExists(at: syncedDest)
        }
        XCTAssertTrue(bothSynced, "源文件与复制文件应该已同步到客户端2")

        if bothSynced {
            let sourceContent = try TestHelpers.readFileContent(at: syncedSource)
            let destContent = try TestHelpers.readFileContent(at: syncedDest)
            XCTAssertEqual(sourceContent, destContent, "复制文件内容应该与源文件一致")
            XCTAssertEqual(sourceContent, "Source content", "文件内容应该正确")
        }
    }

    /// 测试复制文件夹
    func testCopyFile_Folder() async throws {
        // 创建源文件夹
        let sourceDir = tempDir1.appendingPathComponent("source_dir")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let file1 = sourceDir.appendingPathComponent("file1.txt")
        try TestHelpers.createTestFile(at: file1, content: "File 1")

        let file2 = sourceDir.appendingPathComponent("file2.txt")
        try TestHelpers.createTestFile(at: file2, content: "File 2")

        // 等待初始同步
        try await Task.sleep(nanoseconds: 6_000_000_000)  // 6秒

        // 复制文件夹
        let destDir = tempDir1.appendingPathComponent("copy_dir")
        try FileManager.default.copyItem(at: sourceDir, to: destDir)

        // 等待同步
        try await Task.sleep(nanoseconds: 8_000_000_000)  // 8秒

        // 验证文件夹及其内容已同步到客户端2
        let syncedSourceDir = tempDir2.appendingPathComponent("source_dir")
        let syncedDestDir = tempDir2.appendingPathComponent("copy_dir")
        let syncedDestFile1 = syncedDestDir.appendingPathComponent("file1.txt")
        let syncedDestFile2 = syncedDestDir.appendingPathComponent("file2.txt")

        let dirsAndFilesSynced = await TestHelpers.waitForCondition(timeout: 28.0) {
            TestHelpers.directoryExists(at: syncedSourceDir)
                && TestHelpers.directoryExists(at: syncedDestDir)
                && TestHelpers.fileExists(at: syncedDestFile1)
                && TestHelpers.fileExists(at: syncedDestFile2)
        }
        XCTAssertTrue(dirsAndFilesSynced, "源文件夹、复制文件夹及其中文件应该已同步到客户端2")

        if dirsAndFilesSynced {
            let content1 = try TestHelpers.readFileContent(at: syncedDestFile1)
            let content2 = try TestHelpers.readFileContent(at: syncedDestFile2)
            XCTAssertEqual(content1, "File 1", "文件1内容应该正确")
            XCTAssertEqual(content2, "File 2", "文件2内容应该正确")
        }
    }

    // MARK: - 重命名文件测试

    /// 测试客户端A重命名文件，客户端B同步
    func testRenameFile_SingleFile() async throws {
        // 创建文件
        let oldFile = tempDir1.appendingPathComponent("old_name.txt")
        try TestHelpers.createTestFile(at: oldFile, content: "File content")

        // 等待初始同步
        try await Task.sleep(nanoseconds: 6_000_000_000)  // 6秒

        // 重命名文件
        let newFile = tempDir1.appendingPathComponent("new_name.txt")
        try FileManager.default.moveItem(at: oldFile, to: newFile)

        // 等待同步（旧文件消失、新文件出现）
        let syncedOldFile = tempDir2.appendingPathComponent("old_name.txt")
        let syncedNewFile = tempDir2.appendingPathComponent("new_name.txt")
        let renamed = await TestHelpers.waitForCondition(timeout: 28.0) {
            !TestHelpers.fileExists(at: syncedOldFile) && TestHelpers.fileExists(at: syncedNewFile)
        }
        XCTAssertTrue(renamed, "旧文件应已删除且新文件应已同步到客户端2")

        if renamed {
            let content = try TestHelpers.readFileContent(at: syncedNewFile)
            XCTAssertEqual(content, "File content", "文件内容应该一致")
        }
    }

    /// 测试重命名文件夹
    func testRenameFile_Folder() async throws {
        // 创建文件夹
        let oldDir = tempDir1.appendingPathComponent("old_folder")
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)

        let file1 = oldDir.appendingPathComponent("file1.txt")
        try TestHelpers.createTestFile(at: file1, content: "File 1")

        let file2 = oldDir.appendingPathComponent("file2.txt")
        try TestHelpers.createTestFile(at: file2, content: "File 2")

        // 等待初始同步
        try await Task.sleep(nanoseconds: 6_000_000_000)  // 6秒

        // 重命名文件夹
        let newDir = tempDir1.appendingPathComponent("new_folder")
        try FileManager.default.moveItem(at: oldDir, to: newDir)

        // 等待同步：旧目录消失、新目录及文件出现
        let syncedOldDir = tempDir2.appendingPathComponent("old_folder")
        let syncedNewDir = tempDir2.appendingPathComponent("new_folder")
        let syncedFile1 = syncedNewDir.appendingPathComponent("file1.txt")
        let syncedFile2 = syncedNewDir.appendingPathComponent("file2.txt")

        let renamed = await TestHelpers.waitForCondition(timeout: 28.0) {
            !TestHelpers.directoryExists(at: syncedOldDir)
                && TestHelpers.directoryExists(at: syncedNewDir)
                && TestHelpers.fileExists(at: syncedFile1)
                && TestHelpers.fileExists(at: syncedFile2)
        }
        XCTAssertTrue(renamed, "旧文件夹应已删除，新文件夹及文件应已同步到客户端2")

        if renamed {
            let content1 = try TestHelpers.readFileContent(at: syncedFile1)
            let content2 = try TestHelpers.readFileContent(at: syncedFile2)
            XCTAssertEqual(content1, "File 1", "文件1内容应该正确")
            XCTAssertEqual(content2, "File 2", "文件2内容应该正确")
        }
    }

    /// 测试重命名检测（通过哈希值匹配）
    func testRenameFile_HashMatching() async throws {
        // 创建文件
        let originalFile = tempDir1.appendingPathComponent("original.txt")
        let originalContent = "Original content with unique hash"
        try TestHelpers.createTestFile(at: originalFile, content: originalContent)

        // 等待初始同步
        try await Task.sleep(nanoseconds: 6_000_000_000)  // 6秒

        // 重命名文件（不修改内容）
        let renamedFile = tempDir1.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: originalFile, to: renamedFile)

        // 等待同步：旧文件消失、新文件存在且内容一致
        let syncedOriginal = tempDir2.appendingPathComponent("original.txt")
        let syncedRenamed = tempDir2.appendingPathComponent("renamed.txt")
        let renamed = await TestHelpers.waitForCondition(timeout: 28.0) {
            !TestHelpers.fileExists(at: syncedOriginal)
                && TestHelpers.fileExists(at: syncedRenamed)
                && (try? TestHelpers.readFileContent(at: syncedRenamed)) == originalContent
        }
        XCTAssertTrue(renamed, "旧文件应已删除，重命名后文件应已同步且内容一致")

        if renamed {
            let content = try TestHelpers.readFileContent(at: syncedRenamed)
            XCTAssertEqual(content, originalContent, "文件内容应该一致（通过哈希值匹配检测重命名）")
        }
    }
}
