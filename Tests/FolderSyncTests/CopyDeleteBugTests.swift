import XCTest

@testable import FolderSync

class CopyDeleteBugTests: XCTestCase {

    // Test the scenario where a file is copied locally (creating a new file with fresh VC)
    // but the remote peer has a tombstone for that path (from a previous deletion).
    func testCopyFileDeletedByRemote() {
        // Setup
        let path = "test_file.txt"
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)

        // Local: New file created (simulating a copy)
        // A new file typically has a new VC {Local: 1} or similar, or empty VC if just created and not synced yet.
        // Let's assume it has no VC yet or a fresh one.
        // In the app, when a file is created, it might not have a VC until synced.
        // But FileMetadata might pick up one?

        // Scenario A: Local file has NO VC (just created)
        let localMetaNoVC = FileMetadata(
            hash: "abc",
            mtime: now,
            creationDate: now,
            vectorClock: nil,  // New file might not have VC yet
            isDirectory: false
        )

        // Remote: File was deleted long ago
        let remoteVC = VectorClock(versions: ["Remote": 5, "Local": 2])
        let remoteDeletion = DeletionRecord(
            deletedAt: oneHourAgo,
            deletedBy: "Remote",
            vectorClock: remoteVC
        )
        let remoteState = FileState.deleted(remoteDeletion)

        // Decision
        let actionNoVC = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMetaNoVC),
            remoteState: remoteState,
            path: path
        )

        print("Action (No VC): \(actionNoVC)")

        // Expectation: Should NOT delete local file. Should UPLOAD (resurrect) or CONFLICT.
        // If it returns .deleteLocal, it's a bug.

        // Scenario B: Local file has fresh VC {Local: 3} (incremented from previous knowledge?)
        // If it's a COPY, it's a new file.
        let localVC = VectorClock(versions: ["Local": 3])
        // Note: Local:3 is NOT comparable to Remote:5, Local:2 (Remote has seen Local:2).
        // Local:3 is a successor of Local:2.
        // So {Local: 3} vs {Remote: 5, Local: 2} -> Concurrent?
        // Remote:5 is not seen by Local.

        let localMetaWithVC = FileMetadata(
            hash: "abc",
            mtime: now,
            creationDate: now,
            vectorClock: localVC,
            isDirectory: false
        )

        let actionWithVC = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMetaWithVC),
            remoteState: remoteState,
            path: path
        )

        print("Action (With VC): \(actionWithVC)")

    }
}
