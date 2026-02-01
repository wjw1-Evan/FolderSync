import XCTest

@testable import FolderSync

final class BatchVectorClockTests: XCTestCase {
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

    func testBatchVectorClockPersistence() async throws {
        // Setup a sync folder
        let folderID = UUID()
        let folder = SyncFolder(
            id: folderID,
            syncID: "batch_vc_test_sync_id",
            localPath: tempFolder
        )
        await MainActor.run {
            syncManager.folders = [folder]
        }

        // Start P2PNode to generate PeerID
        try await syncManager.p2pNode.start()
        guard let myPeerID = await syncManager.p2pNode.peerID?.b58String else {
            XCTFail("PeerID should be generated after start")
            return
        }

        // Create multiple files
        let fileCount = 5
        var paths = Set<String>()
        for i in 0..<fileCount {
            let filename = "file_\(i).txt"
            let fileURL = tempFolder.appendingPathComponent(filename)
            try "content \(i)".write(to: fileURL, atomically: true, encoding: .utf8)
            paths.insert(fileURL.path)
        }

        // Wait a bit for file system
        try await Task.sleep(nanoseconds: 100_000_000)

        // Call recordBatchLocalChanges
        let flags = paths.reduce(into: [String: FSEventStreamEventFlags]()) {
            $0[$1] = FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified)
        }

        await syncManager.recordBatchLocalChanges(for: folder, paths: paths, flags: flags)

        // Allow some time for detached task to complete writing
        try await Task.sleep(nanoseconds: 1_000_000_000)  // Increase wait time just in case

        // Verify that Vector Clocks are persisted
        for i in 0..<fileCount {
            let filename = "file_\(i).txt"
            // Use StorageManager directly to verify persistence
            let vc = StorageManager.shared.getVectorClock(
                folderID: folderID,
                syncID: folder.syncID,
                path: filename
            )
            XCTAssertNotNil(vc, "Vector Clock for \(filename) should be persisted")
            XCTAssertEqual(
                vc?.versions[myPeerID], 1,
                "Vector Clock should be incremented for peerID: \(myPeerID)")
        }
    }
}
