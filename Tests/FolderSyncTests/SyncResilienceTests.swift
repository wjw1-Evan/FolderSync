import XCTest

@testable import FolderSync

// MARK: - README § 十 Sync Verification Checklist Tests
//
// README 同步测试指南要求重点关注以下一致性指标：
//   ✓ 哈希一致性  — 同步后两端内容哈希/MST 根哈希完全一致
//   ✓ 因果有序性  — VectorClock 随编辑递增，新版本始终覆盖旧版本
//   ✓ 冲突处理    — 双方同时编辑同一文件产生 .conflict 文件，不丢数据
//   ✓ 离线追赶    — Node B 离线期间 A 多次编辑，B 上线后正确合并增量
//   ✓ 空目录与重命名同步准确性
//
// 全部测试通过纯单元方式（仅调用 SyncDecisionEngine / VectorClock / MST）实现，
// 不依赖网络栈，可在 CI 环境中快速稳定运行。

final class SyncResilienceTests: XCTestCase {

    // MARK: - Helpers

    private func makeState(hash: String, vc: [String: Int], mtime: Date = Date()) -> FileState {
        let meta = FileMetadata(
            hash: hash,
            mtime: mtime,
            creationDate: mtime,
            vectorClock: VectorClock(versions: vc),
            isDirectory: false
        )
        return .exists(meta)
    }

    private func makeDeletedState(vc: [String: Int], at date: Date = Date()) -> FileState {
        let record = DeletionRecord(
            deletedAt: date, deletedBy: "peer", vectorClock: VectorClock(versions: vc))
        return .deleted(record)
    }

    private func decide(local: FileState?, remote: FileState?, path: String = "test.txt")
        -> SyncDecisionEngine.SyncAction
    {
        return SyncDecisionEngine.decideSyncAction(
            localState: local, remoteState: remote, path: path)
    }

    // MARK: - 因果有序性 (Causal Ordering)
    // README: 通过日志观察 VectorClock 是否随编辑动作递增，且新版本始终覆盖旧版本

    func testCausalOrder_LocalEdited_ShouldUpload() {
        // A edits file: localVC [A:2] is successor of remoteVC [A:1]
        let local = makeState(hash: "v2", vc: ["A": 2])
        let remote = makeState(hash: "v1", vc: ["A": 1])
        XCTAssertEqual(
            decide(local: local, remote: remote), .upload,
            "After A edits, successor VC must cause upload")
    }

    func testCausalOrder_RemoteEdited_ShouldDownload() {
        // B edits file: remoteVC [B:3] is successor of localVC [B:1]
        let local = makeState(hash: "v1", vc: ["B": 1])
        let remote = makeState(hash: "v3", vc: ["B": 3])
        XCTAssertEqual(
            decide(local: local, remote: remote), .download,
            "When remote VC is successor, should download")
    }

    func testCausalOrder_MultiPeer_ChainCausality() {
        // Three-device causal chain: A→B→C edit sequence
        // Local (A,B both knew C's edit): [A:1, B:2, C:1]
        // Remote (only knew A's edit):    [A:1, B:0, C:0] → predecessor
        let local = makeState(hash: "v3", vc: ["A": 1, "B": 2, "C": 1])
        let remote = makeState(hash: "v1", vc: ["A": 1])
        XCTAssertEqual(
            decide(local: local, remote: remote), .upload,
            "Local knows more history — should upload")
    }

    // MARK: - 哈希一致性 (Hash Consistency)
    // README: 同步完成后，两端文件夹内文件内容哈希完全一致

    func testHashConsistency_IdenticalContent_Skip() {
        // Same hash means content is identical regardless of VC
        let local = makeState(hash: "sha256-abc123", vc: ["A": 1])
        let remote = makeState(hash: "sha256-abc123", vc: ["B": 1])
        XCTAssertEqual(
            decide(local: local, remote: remote), .skip,
            "Identical hash must skip — no network transfer needed")
    }

    func testHashConsistency_MSTRootHashIsDeterministic() {
        // After full sync: both MSTs must produce the same root hash
        let sharedFiles = [
            ("docs/readme.md", "hash-r"),
            ("src/main.swift", "hash-m"),
            ("tests/foo_test.swift", "hash-t"),
        ]

        let mstA = MerkleSearchTree()
        let mstB = MerkleSearchTree()
        // Simulate different insertion orders (as would happen on independent nodes)
        for (k, v) in sharedFiles { mstA.insert(key: k, value: v) }
        for (k, v) in sharedFiles.reversed() { mstB.insert(key: k, value: v) }

        XCTAssertEqual(
            mstA.rootHash, mstB.rootHash,
            "After sync, both peers must arrive at the same MST root hash")
    }

    // MARK: - 冲突处理 (Conflict Handling)
    // README: 双方同时编辑同一文件时，应产生 .conflict 后缀的冲突文件，不丢数据

    func testConflict_ConcurrentEdits_DetectedCorrectly() {
        // A and B both edited independently: truly concurrent VCs
        let local = makeState(hash: "local-v", vc: ["A": 2, "B": 1])
        let remote = makeState(hash: "remote-v", vc: ["A": 1, "B": 2])
        XCTAssertEqual(
            decide(local: local, remote: remote), .conflict,
            "Concurrent edits must be flagged as conflict to preserve both versions")
    }

    func testConflict_ThreeDevices_AllConcurrent_IsConflict() {
        // Devices A, B, C all edited simultaneously; no causal relationship
        let local = makeState(hash: "va", vc: ["A": 2, "B": 1, "C": 1])
        let remote = makeState(hash: "vb", vc: ["A": 1, "B": 2, "C": 1])
        XCTAssertEqual(
            decide(local: local, remote: remote), .conflict,
            "Three-way concurrent edit is still a conflict")
    }

    func testNoConflict_OnlyOneEdited_NeverConflict() {
        // Only A edited. A's change clearly dominates.
        let local = makeState(hash: "new", vc: ["A": 3, "B": 1])
        let remote = makeState(hash: "old", vc: ["A": 1, "B": 1])
        let action = decide(local: local, remote: remote)
        XCTAssertNotEqual(
            action, .conflict,
            "Clear successor must not be mistaken for conflict")
        XCTAssertEqual(action, .upload)
    }

    // MARK: - 离线追赶 (Offline Catch-Up)
    // README: Node B 离线时 Node A 进行多次编辑，B 重新上线后能正确合并增量变更

    func testOfflineCatchUp_MultipleEditsWhileOffline() {
        // Simulates: B was at [A:1, B:1]. Then A edited 5 more times (A:6).
        // B comes online, compares states.
        let bLocalState = makeState(hash: "v1", vc: ["A": 1, "B": 1])  // B's stale copy
        let aRemoteState = makeState(hash: "v6", vc: ["A": 6, "B": 1])  // A's latest
        XCTAssertEqual(
            decide(local: bLocalState, remote: aRemoteState), .download,
            "B must download all of A's accumulated edits after coming back online")
    }

    func testOfflineCatchUp_BothEditedWhileOffline_Conflict() {
        // B was stale, but ALSO edited locally while offline — true conflict
        let bLocalEdited = makeState(hash: "b-edit", vc: ["A": 1, "B": 3])  // B edited 2x offline
        let aRemoteEdited = makeState(hash: "a-edit", vc: ["A": 3, "B": 1])  // A edited 2x while B was offline
        XCTAssertEqual(
            decide(local: bLocalEdited, remote: aRemoteEdited), .conflict,
            "Both sides edited while disconnected — conflict must be detected")
    }

    func testOfflineCatchUp_BDeletedWhileOffline_ShouldDeleteLocal() {
        // While B was offline, A deleted the file with a more advanced VC.
        let bLocalState = makeState(hash: "stale", vc: ["A": 1, "B": 1])
        let aDeletion = makeDeletedState(vc: ["A": 3, "B": 1])
        XCTAssertEqual(
            decide(local: bLocalState, remote: aDeletion), .deleteLocal,
            "A's deletion with successor VC must propagate to B on reconnect")
    }

    // MARK: - 空目录与重命名 (Empty Dir & Rename)
    // README: 验证空目录创建、目录嵌套重命名等操作的同步准确性

    func testEmptyDir_RemoteCreated_ShouldDownload() {
        // Remote created an empty directory (treated as a file entry with isDirectory=true)
        let remoteVC = VectorClock(versions: ["B": 1])
        let remoteDirMeta = FileMetadata(
            hash: "", mtime: Date(), creationDate: Date(),
            vectorClock: remoteVC, isDirectory: true)
        let action = SyncDecisionEngine.decideSyncAction(
            localState: nil,
            remoteState: .exists(remoteDirMeta),
            path: "photos/2024/"
        )
        XCTAssertEqual(
            action, .download,
            "Remote-only directory must be downloaded")
    }

    func testRename_OldPathTombstone_ShouldBeDeleted() {
        // A renamed file.txt → renamed.txt. Old path has tombstone with higher VC.
        let local = makeState(hash: "content", vc: ["A": 1])  // stale local copy
        let remote = makeDeletedState(vc: ["A": 2])  // A deleted (renamed away)
        XCTAssertEqual(
            decide(local: local, remote: remote), .deleteLocal,
            "Old path after rename: tombstone with successor VC deletes local stale copy")
    }

    func testRename_NewPathDoesntExistLocally_ShouldDownload() {
        // A renamed file.txt → renamed.txt. New path only exists on remote.
        let remote = makeState(hash: "content", vc: ["A": 2])
        XCTAssertEqual(
            decide(local: nil, remote: remote), .download,
            "New path after rename: must be downloaded by peer that doesn't have it")
    }

    func testRename_NestedDirectory_BothOldAndNewPaths() {
        // Renaming src/ → lib/ — each path is tested independently
        let nestedOldLocal = makeState(hash: "h", vc: ["A": 1])
        let nestedOldRemote = makeDeletedState(vc: ["A": 2])  // A deleted src/file.swift
        XCTAssertEqual(
            decide(local: nestedOldLocal, remote: nestedOldRemote), .deleteLocal,
            "Nested file in old dir must be deleted")

        let nestedNewRemote = makeState(hash: "h", vc: ["A": 2])  // A has lib/file.swift
        XCTAssertEqual(
            decide(local: nil, remote: nestedNewRemote), .download,
            "Nested file in new dir must be downloaded")
    }

    // MARK: - 文件复活 (File Resurrection)
    // README: 当本地文件修改时间明显晚于远程删除记录时，系统判定为"复活"并保留本地文件

    func testResurrection_NewerMtime_ShouldUpload() {
        // File deleted remotely (mtime-based resurrection heuristic)
        let deletedAt = Date(timeIntervalSinceNow: -3600)  // 1 hour ago
        let record = DeletionRecord(
            deletedAt: deletedAt, deletedBy: "B",
            vectorClock: VectorClock(versions: ["B": 1]))
        // Local file has nil VC (newly created/recreated) and newer mtime
        let localMeta = FileMetadata(
            hash: "new-content",
            mtime: Date(),  // just now
            creationDate: Date(),
            vectorClock: nil,  // no VC yet for brand-new file
            isDirectory: false
        )
        let action = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMeta),
            remoteState: .deleted(record),
            path: "resurrected.txt"
        )
        XCTAssertEqual(
            action, .upload,
            "File recreated after deletion (newer mtime) must be resurrected via upload")
    }

    func testResurrection_OlderMtime_TombstoneWins() {
        // Local file exists but its mtime predates the deletion — it's just a stale copy.
        let now = Date()
        let record = DeletionRecord(
            deletedAt: now, deletedBy: "B",
            vectorClock: VectorClock(versions: ["A": 1, "B": 2]))
        let localMeta = FileMetadata(
            hash: "stale",
            mtime: now.addingTimeInterval(-10),  // older than deletion
            creationDate: now.addingTimeInterval(-100),
            vectorClock: VectorClock(versions: ["A": 1]),
            isDirectory: false
        )
        let action = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMeta),
            remoteState: .deleted(record),
            path: "old.txt"
        )
        XCTAssertEqual(
            action, .deleteLocal,
            "File older than deletion record and with lower VC must be deleted locally")
    }
}
