import XCTest

@testable import FolderSync

@MainActor
final class SyncIDManagerTests: XCTestCase {
    private func waitForMainActorTasks(file: StaticString = #file, line: UInt = #line) {
        let exp = expectation(description: "flush main actor tasks")
        Task { @MainActor in exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    func testRegisterLookupAndUnregister() {
        let manager = SyncIDManager()
        let folderID = UUID()
        let syncID = "SYNC1234"

        XCTAssertTrue(manager.registerSyncID(syncID, folderID: folderID))
        XCTAssertFalse(
            manager.registerSyncID(syncID, folderID: UUID()), "duplicate syncID should be rejected")
        XCTAssertFalse(
            manager.registerSyncID("ANOTHER", folderID: folderID),
            "folderID already bound should be rejected")

        XCTAssertEqual(manager.totalSyncIDCount, 1)
        XCTAssertEqual(manager.getSyncID(for: folderID), syncID)
        XCTAssertEqual(manager.getAllSyncIDs().count, 1)

        let info = manager.getSyncIDInfo(syncID)
        XCTAssertEqual(info?.folderID, folderID)
        XCTAssertEqual(info?.syncID, syncID)

        manager.unregisterSyncID(syncID)
        waitForMainActorTasks()

        XCTAssertNil(manager.getSyncID(for: folderID))
        XCTAssertNil(manager.getSyncIDInfo(syncID))
        XCTAssertFalse(manager.hasSyncID(syncID))
    }

    func testPeerManagementAndLastSynced() {
        let manager = SyncIDManager()
        let folderID = UUID()
        let syncID = "SYNC-PEER"

        XCTAssertTrue(manager.registerSyncID(syncID, folderID: folderID))

        manager.addPeer("peer1", to: syncID)
        manager.addPeer("peer2", to: syncID)
        waitForMainActorTasks()

        XCTAssertEqual(manager.getPeerCount(for: syncID), 2)
        XCTAssertEqual(manager.getPeers(for: syncID), Set(["peer1", "peer2"]))

        manager.removePeer("peer1", from: syncID)
        waitForMainActorTasks()
        XCTAssertEqual(manager.getPeers(for: syncID), Set(["peer2"]))

        let customDate = Date(timeIntervalSinceNow: -120)
        manager.updateLastSyncedAt(syncID, date: customDate)
        waitForMainActorTasks()
        let lastSynced = manager.getSyncIDInfo(syncID)?.lastSyncedAt
        XCTAssertNotNil(lastSynced)
        XCTAssertEqual(
            lastSynced?.timeIntervalSince1970 ?? 0, customDate.timeIntervalSince1970, accuracy: 0.01
        )

        manager.unregisterSyncIDByFolderID(folderID)
        waitForMainActorTasks()
        XCTAssertFalse(manager.hasSyncID(syncID))
    }

    func testValidationHelpers() {
        let generated = SyncIDManager.generateSyncID(length: 12)
        XCTAssertEqual(generated.count, 12)
        XCTAssertTrue(SyncIDManager.isValidSyncID("abcd1234"))
        XCTAssertFalse(SyncIDManager.isValidSyncID("a!c"), "non-alphanumeric should be rejected")
        XCTAssertFalse(SyncIDManager.isValidSyncID("abc"), "too short should be rejected")
    }
}
