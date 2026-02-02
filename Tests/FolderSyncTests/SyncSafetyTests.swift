import XCTest

@testable import FolderSync

class SyncSafetyTests: XCTestCase {

    // MARK: - Helper Methods

    enum MockState {
        case exists(vc: VectorClock?, mtime: Date)
        case deleted(vc: VectorClock, at: Date)
        case none
    }

    func makeEngineDecision(local: MockState, remote: MockState) -> SyncDecisionEngine.SyncAction {
        let localState: FileState?
        switch local {
        case .exists(let vc, let mtime):
            let meta = FileMetadata(
                hash: "hash", mtime: mtime, creationDate: mtime, vectorClock: vc, isDirectory: false
            )
            localState = .exists(meta)
        case .deleted(let vc, let at):
            let record = DeletionRecord(deletedAt: at, deletedBy: "test", vectorClock: vc)
            localState = .deleted(record)
        case .none:
            localState = nil
        }

        let remoteState: FileState?
        switch remote {
        case .exists(let vc, let mtime):
            let meta = FileMetadata(
                hash: "remote_hash", mtime: mtime, creationDate: mtime, vectorClock: vc,
                isDirectory: false)
            remoteState = .exists(meta)
        case .deleted(let vc, let at):
            let record = DeletionRecord(deletedAt: at, deletedBy: "remote", vectorClock: vc)
            remoteState = .deleted(record)
        case .none:
            remoteState = nil
        }

        return SyncDecisionEngine.decideSyncAction(
            localState: localState, remoteState: remoteState, path: "test.txt")
    }

    // MARK: - Safety Tests

    // 1. Copy Operation (New File) vs Remote Tombstone
    // Scenario: User copies file A to B. B is new (no VC). Remote has tombstone for B (from past).
    // Risk: Deleting the new copy B.
    func testSafeguard_NewCopyVsOldTombstone() {
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)

        let local = MockState.exists(vc: nil, mtime: now)  // New copy, no VC check
        let remote = MockState.deleted(vc: VectorClock(versions: ["A": 1]), at: oneHourAgo)

        let decision = makeEngineDecision(local: local, remote: remote)

        // MUST NOT be deleteLocal
        XCTAssertEqual(decision, .upload, "New file should be uploaded (resurrected), not deleted")
    }

    // 2. Modified File vs Remote Tombstone (Concurrent)
    // Scenario: User modifies B (VC: {A:1}). Remote deletes B (VC: {A:1, B:1}).
    // This is a "Delete Wins" vs "Modify Wins" conflict?
    // Actually, if Remote has {A:1, B:1} and Local has {A:1}, then Remote dominates.
    // BUT if Local has modified it, Local should have {A:1, Local:1} (new version).
    // Case: Local {A:1, Local:1} vs Remote Tombstone {A:1} -> Local dominates -> Upload (Resurrect).
    func testSafeguard_ModifiedVsOldTombstone() {
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)

        let localVC = VectorClock(versions: ["A": 1, "Local": 1])
        let remoteVC = VectorClock(versions: ["A": 1])  // Older VC

        let local = MockState.exists(vc: localVC, mtime: now)
        let remote = MockState.deleted(vc: remoteVC, at: oneHourAgo)

        let decision = makeEngineDecision(local: local, remote: remote)

        XCTAssertEqual(decision, .upload, "Modified file with newer VC should overwrite tombstone")
    }

    // 3. Concurrent Modify vs Delete
    // Case: Local {A:1, Local:1} vs Remote Tombstone {A:1, Remote:1}
    // They are concurrent.
    func testSafeguard_ConcurrentModifyVsDelete() {
        let now = Date()

        let localVC = VectorClock(versions: ["A": 1, "Local": 1])
        let remoteVC = VectorClock(versions: ["A": 1, "Remote": 1])

        let local = MockState.exists(vc: localVC, mtime: now)
        let remote = MockState.deleted(vc: remoteVC, at: now)

        let decision = makeEngineDecision(local: local, remote: remote)

        // Should be CONFLICT or UPLOAD (preferring data preservation)
        // Current logic might return .conflict or .upload depending on timestamps.

        // If mtime is close (< 1s), it returns .conflict
        // Let's verify it is at least NOT .deleteLocal
        XCTAssertNotEqual(
            decision, .deleteLocal, "Concurrent modification should not be silently deleted")

        // Ideally .conflict or .upload
        XCTAssertTrue(decision == .conflict || decision == .upload)
    }

    // 4. "The Resurrection Bug" - Rapid Recreate
    // Scenario: File deleted, then immediately recreated with same name.
    // Local: Deleted(VC: {A:1}) -> Created(VC: nil/fresh, mtime: now)
    // Remote: Deleted(VC: {A:1})
    // Local State is effectively .exists(VC: nil). Remote is .deleted.
    // This overlaps with testSafeguard_NewCopyVsOldTombstone but timing is tighter.
    func testSafeguard_RapidRecreateVsRemoteTombstone() {
        let now = Date()
        let remoteDeletedAt = now.addingTimeInterval(-2)  // 2 seconds ago

        let local = MockState.exists(vc: nil, mtime: now)
        let remote = MockState.deleted(vc: VectorClock(versions: ["A": 1]), at: remoteDeletedAt)

        let decision = makeEngineDecision(local: local, remote: remote)

        XCTAssertEqual(decision, .upload, "Recreated file (newer mtime) should resurrect")
    }

    // 5. Remote Delete Dominates (Legitimate Delete)
    // Scenario: Local {A:1}. Remote Tombstone {A:1, Remote:1}.
    // Local has NOT modified. Remote deleted it.
    // Decision should be .deleteLocal.
    func testLegitimateRemoteDelete() {
        let now = Date()
        let past = now.addingTimeInterval(-100)

        let localVC = VectorClock(versions: ["A": 1])
        let remoteVC = VectorClock(versions: ["A": 1, "Remote": 1])  // Remote is successor

        let local = MockState.exists(vc: localVC, mtime: past)
        let remote = MockState.deleted(vc: remoteVC, at: now)

        let decision = makeEngineDecision(local: local, remote: remote)

        XCTAssertEqual(
            decision, .deleteLocal,
            "If remote VC dominates and local hasn't changed, delete should happen")
    }

    // 6. Confusing Case: VC Equal?
    // Scenario: Local {A:1}, Remote Tombstone {A:1}.
    // This implies Local IS the file that was deleted? Or state mismatch?
    // If timestamps are wide apart?
    func testVCEqual_RemoteDeleted() {
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)

        let vc = VectorClock(versions: ["A": 1])

        // Case A: Local file is OLD (equal to deletion time roughly) -> Delete
        let localOld = MockState.exists(vc: vc, mtime: oneHourAgo)
        let remote = MockState.deleted(vc: vc, at: oneHourAgo)

        let decisionOld = makeEngineDecision(local: localOld, remote: remote)
        // If mtime diff < 1.0 -> deleteLocal
        XCTAssertEqual(
            decisionOld, .deleteLocal,
            "If VCs equal and timestamps close, assume consistent state (deleted)")

        // Case B: Local file is NEW (resurrected with same content/VC?) -> Upload
        let localNew = MockState.exists(vc: vc, mtime: now)
        let decisionNew = makeEngineDecision(local: localNew, remote: remote)

        XCTAssertEqual(
            decisionNew, .upload, "If VCs equal but local file is much newer, treat as resurrection"
        )
    }
}
