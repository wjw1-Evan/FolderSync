import CoreServices
import XCTest

@testable import FolderSync

final class FileSystemOperationsTests: XCTestCase {
    var syncManager: SyncManager!
    var tempFolder: URL!
    var folder: SyncFolder!

    override func setUp() async throws {
        try await super.setUp()
        syncManager = await SyncManager()

        // Create a unique temporary directory for each test
        let uniqueID = UUID().uuidString
        tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FolderSyncTests_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)

        folder = SyncFolder(
            id: UUID(),
            syncID: "test_sync_\(uniqueID)",
            localPath: tempFolder
        )

        await MainActor.run {
            syncManager.folders = [folder]
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempFolder)
        syncManager = nil
        try await super.tearDown()
    }

    // MARK: - Helper Methods

    private func simulateEvent(paths: Set<String>, flags: [String: FSEventStreamEventFlags]) async {
        await syncManager.recordBatchLocalChanges(for: folder, paths: paths, flags: flags)
    }

    // MARK: - Tests

    /// 测试文件添加
    func testFileAddition() async throws {
        let filename = "new_file.txt"
        let fileURL = tempFolder.appendingPathComponent(filename)
        try "Hello World".write(to: fileURL, atomically: true, encoding: .utf8)

        let path = fileURL.path
        let flags: [String: FSEventStreamEventFlags] = [
            path: FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified)
        ]

        await simulateEvent(paths: [path], flags: flags)

        let metadata = await syncManager.lastKnownMetadata[folder.syncID]
        XCTAssertNotNil(metadata?[filename], "文件应该被记录在元数据中")
        XCTAssertEqual(metadata?[filename]?.size, 11)
    }

    /// 测试文件夹添加及其子文件
    func testFolderAddition() async throws {
        let subfolderName = "subfolder"
        let subfolderURL = tempFolder.appendingPathComponent(subfolderName)
        try FileManager.default.createDirectory(at: subfolderURL, withIntermediateDirectories: true)

        let filename = "inner_file.txt"
        let fileURL = subfolderURL.appendingPathComponent(filename)
        try "Inner Content".write(to: fileURL, atomically: true, encoding: .utf8)

        let subfolderPath = subfolderURL.path
        let filePath = fileURL.path

        let flags: [String: FSEventStreamEventFlags] = [
            subfolderPath: FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir),
            filePath: FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified),
        ]

        await simulateEvent(paths: [subfolderPath, filePath], flags: flags)

        let metadata = await syncManager.lastKnownMetadata[folder.syncID]
        let relativeFilePath = "\(subfolderName)/\(filename)"
        XCTAssertNotNil(metadata?[relativeFilePath], "子文件夹中的文件应该被记录")
    }

    /// 测试文件更新/修改
    func testFileUpdate() async throws {
        // 先添加文件
        let filename = "update_test.txt"
        let fileURL = tempFolder.appendingPathComponent(filename)
        try "Initial".write(to: fileURL, atomically: true, encoding: .utf8)

        await simulateEvent(
            paths: [fileURL.path],
            flags: [fileURL.path: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)])

        let initialMetadata = await syncManager.lastKnownMetadata[folder.syncID]?[filename]
        XCTAssertNotNil(initialMetadata)

        // 修改文件内容
        try await Task.sleep(nanoseconds: 100_000_000)  // 确保时间戳不同 (if needed)
        try "Updated Content".write(to: fileURL, atomically: true, encoding: .utf8)

        await simulateEvent(
            paths: [fileURL.path],
            flags: [fileURL.path: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)])

        let updatedMetadata = await syncManager.lastKnownMetadata[folder.syncID]?[filename]
        XCTAssertNotEqual(initialMetadata?.hash, updatedMetadata?.hash, "修改后哈希值应该变了")
        XCTAssertEqual(updatedMetadata?.size, 15)
    }

    /// 测试文件删除
    func testFileDeletion() async throws {
        // 先添加文件
        let filename = "delete_me.txt"
        let fileURL = tempFolder.appendingPathComponent(filename)
        try "To be deleted".write(to: fileURL, atomically: true, encoding: .utf8)

        await simulateEvent(
            paths: [fileURL.path],
            flags: [fileURL.path: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)])

        // 删除文件
        try FileManager.default.removeItem(at: fileURL)

        await simulateEvent(
            paths: [fileURL.path],
            flags: [fileURL.path: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)])

        let metadata = await syncManager.lastKnownMetadata[folder.syncID]
        XCTAssertNil(metadata?[filename], "删除后元数据应该被移除")

        let knownPaths = await syncManager.lastKnownLocalPaths[folder.syncID]
        XCTAssertFalse(knownPaths?.contains(filename) ?? true, "删除后已知路径应该移除")
    }

    /// 测试文件复制（被视为两个独立的新建或添加）
    func testFileCopy() async throws {
        let originalName = "original.txt"
        let copyName = "copy.txt"
        let originalURL = tempFolder.appendingPathComponent(originalName)
        let copyURL = tempFolder.appendingPathComponent(copyName)

        try "Same Content".write(to: originalURL, atomically: true, encoding: .utf8)
        await simulateEvent(
            paths: [originalURL.path],
            flags: [originalURL.path: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)])

        try FileManager.default.copyItem(at: originalURL, to: copyURL)
        await simulateEvent(
            paths: [copyURL.path],
            flags: [copyURL.path: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)])

        let metadata = await syncManager.lastKnownMetadata[folder.syncID]
        XCTAssertNotNil(metadata?[originalName])
        XCTAssertNotNil(metadata?[copyName])
        XCTAssertEqual(metadata?[originalName]?.hash, metadata?[copyName]?.hash, "复制的文件哈希值应该相同")
    }

    /// 测试文件改名 (Rename)
    func testFileRename() async throws {
        let oldName = "old_name.txt"
        let newName = "new_name.txt"
        let oldURL = tempFolder.appendingPathComponent(oldName)
        let newURL = tempFolder.appendingPathComponent(newName)

        try "Content".write(to: oldURL, atomically: true, encoding: .utf8)
        await simulateEvent(
            paths: [oldURL.path],
            flags: [oldURL.path: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)])

        // 执行重命名
        try FileManager.default.moveItem(at: oldURL, to: newURL)

        // 模拟 FSEvents 的 Rename 序列：两个具有 Renamed 标志的事件
        let oldFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
        let newFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemCreated)

        await simulateEvent(
            paths: [oldURL.path, newURL.path],
            flags: [
                oldURL.path: oldFlags,
                newURL.path: newFlags,
            ])

        let metadata = await syncManager.lastKnownMetadata[folder.syncID]
        XCTAssertNil(metadata?[oldName], "原文件应该被移除")
        XCTAssertNotNil(metadata?[newName], "新文件应该被记录")
    }

    /// 测试文件夹改名 (Folder Rename)
    func testFolderRename() async throws {
        let oldFolderName = "old_folder"
        let newFolderName = "new_folder"
        let oldFolderURL = tempFolder.appendingPathComponent(oldFolderName)
        let newFolderURL = tempFolder.appendingPathComponent(newFolderName)

        try FileManager.default.createDirectory(at: oldFolderURL, withIntermediateDirectories: true)
        let fileName = "file.txt"
        try "data".write(
            to: oldFolderURL.appendingPathComponent(fileName), atomically: true, encoding: .utf8)

        let oldFilePath = oldFolderURL.appendingPathComponent(fileName).path
        await simulateEvent(
            paths: [oldFolderURL.path, oldFilePath],
            flags: [
                oldFolderURL.path: FSEventStreamEventFlags(
                    kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir),
                oldFilePath: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
            ])

        // 执行重命名
        try FileManager.default.moveItem(at: oldFolderURL, to: newFolderURL)

        // 在实际 FSEvents 中，文件夹重命名会产生一系列事件。
        // 这里简化模拟，只要确保 recordBatchLocalChanges 能处理这些路径即可。
        let newFilePath = newFolderURL.appendingPathComponent(fileName).path
        await simulateEvent(
            paths: [oldFolderURL.path, newFolderURL.path, oldFilePath, newFilePath],
            flags: [
                oldFolderURL.path: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed),
                newFolderURL.path: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed),
                oldFilePath: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed),
                newFilePath: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed),
            ])

        let metadata = await syncManager.lastKnownMetadata[folder.syncID]
        XCTAssertNil(metadata?["\(oldFolderName)/\(fileName)"])
        XCTAssertNotNil(metadata?["\(newFolderName)/\(fileName)"])
    }
}
