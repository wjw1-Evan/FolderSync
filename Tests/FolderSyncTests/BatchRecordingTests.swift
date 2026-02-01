import XCTest

@testable import FolderSync

final class BatchRecordingTests: XCTestCase {
    var syncManager: SyncManager!
    var tempFolder: URL!

    override func setUp() async throws {
        try await super.setUp()
        syncManager = await SyncManager()
        tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: tempFolder)
        syncManager = nil
        try await super.tearDown()
    }

    func testRecordBatchLocalChanges() async throws {
        // Setup a sync folder
        let folderID = UUID()
        let folder = SyncFolder(
            id: folderID,
            syncID: "batch_test_sync_id",
            localPath: tempFolder
        )
        await MainActor.run {
            syncManager.folders = [folder]
        }

        // Create multiple files
        let fileCount = 10
        var paths = Set<String>()
        for i in 0..<fileCount {
            let filename = "file_\(i).txt"
            let fileURL = tempFolder.appendingPathComponent(filename)
            try "content \(i)".write(to: fileURL, atomically: true, encoding: .utf8)
            paths.insert(fileURL.path)
        }

        // Wait a bit for file system (optional, mainly for timestamps)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Call recordBatchLocalChanges
        let flags = paths.reduce(into: [String: FSEventStreamEventFlags]()) {
            $0[$1] = FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified)
        }

        await syncManager.recordBatchLocalChanges(for: folder, paths: paths, flags: flags)

        // Verify that memory state is updated
        let metadata = await syncManager.lastKnownMetadata[folder.syncID]
        XCTAssertNotNil(metadata, "Metadata should be initialized")
        XCTAssertEqual(metadata?.count, fileCount, "Should have metadata for all files")

        for i in 0..<fileCount {
            let filename = "file_\(i).txt"
            XCTAssertNotNil(metadata?[filename], "Metadata for \(filename) should exist")
        }

        // Verify local changes are "recorded" (we can't easily check the detached task storage write,
        // but we can check if it returned valid changes by checking if files are in known paths)
        let knownPaths = await syncManager.lastKnownLocalPaths[folder.syncID]
        XCTAssertEqual(knownPaths?.count, fileCount)
    }
}
