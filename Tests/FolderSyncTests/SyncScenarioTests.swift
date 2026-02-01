import XCTest

@testable import FolderSync

/// 端到端同步场景测试
/// 模拟真实的多客户端同步场景，验证 SyncDecisionEngine 的决策逻辑
final class SyncScenarioTests: XCTestCase {

    // MARK: - Helper Methods

    private func makeFileState(
        hash: String,
        vectorClock: VectorClock,
        mtime: Date = Date()
    ) -> FileState {
        let metadata = FileMetadata.makeTest(
            hash: hash,
            mtime: mtime,
            vectorClock: vectorClock
        )
        return .exists(metadata)
    }

    private func makeDeletedState(
        deletedBy: String,
        vectorClock: VectorClock,
        deletedAt: Date = Date()
    ) -> FileState {
        let record = DeletionRecord.makeTest(
            deletedAt: deletedAt,
            deletedBy: deletedBy,
            vectorClock: vectorClock
        )
        return .deleted(record)
    }

    // MARK: - New File Scenarios

    /// 场景：本地新建文件，远程不存在
    /// 预期：决策为 uncertain（需要检查远程是否有删除记录）
    func testScenario_LocalNewFile_RemoteNotExists() {
        let localVC = VectorClock.makeTest(["peerA": 1])
        let localMeta = FileMetadata.makeTest(hash: "newfile", vectorClock: localVC)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMeta),
            remoteState: nil,
            path: "new_file.txt"
        )

        // 本地存在但远程没有状态时，返回 uncertain
        // 这是因为远程可能有删除记录未传播
        XCTAssertEqual(result, .uncertain)
    }

    /// 场景：远程新建文件，本地不存在
    /// 预期：决策为 download
    func testScenario_RemoteNewFile_LocalNotExists() {
        let remoteVC = VectorClock.makeTest(["peerB": 1])
        let remoteMeta = FileMetadata.makeTest(hash: "remotefile", vectorClock: remoteVC)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: nil,
            remoteState: .exists(remoteMeta),
            path: "remote_file.txt"
        )

        XCTAssertEqual(result, .download)
    }

    // MARK: - File Modification Scenarios

    /// 场景：本地修改文件，远程未变
    /// 预期：决策为 upload
    func testScenario_LocalModification_Upload() {
        let localVC = VectorClock.makeTest(["peerA": 3, "peerB": 1])  // 本地递增了 peerA
        let remoteVC = VectorClock.makeTest(["peerA": 1, "peerB": 1])

        let localMeta = FileMetadata.makeTest(hash: "modified_local", vectorClock: localVC)
        let remoteMeta = FileMetadata.makeTest(hash: "original", vectorClock: remoteVC)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMeta),
            remoteState: .exists(remoteMeta),
            path: "modified.txt"
        )

        XCTAssertEqual(result, .upload)
    }

    /// 场景：远程修改文件，本地未变
    /// 预期：决策为 download
    func testScenario_RemoteModification_Download() {
        let localVC = VectorClock.makeTest(["peerA": 1, "peerB": 1])
        let remoteVC = VectorClock.makeTest(["peerA": 1, "peerB": 5])  // 远程递增了 peerB

        let localMeta = FileMetadata.makeTest(hash: "original", vectorClock: localVC)
        let remoteMeta = FileMetadata.makeTest(hash: "modified_remote", vectorClock: remoteVC)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMeta),
            remoteState: .exists(remoteMeta),
            path: "modified.txt"
        )

        XCTAssertEqual(result, .download)
    }

    /// 场景：双方同时修改文件（并发修改）
    /// 预期：决策为 conflict
    func testScenario_ConcurrentModification_Conflict() {
        let localVC = VectorClock.makeTest(["peerA": 3, "peerB": 1])  // A 修改了
        let remoteVC = VectorClock.makeTest(["peerA": 1, "peerB": 3])  // B 也修改了

        let localMeta = FileMetadata.makeTest(hash: "local_version", vectorClock: localVC)
        let remoteMeta = FileMetadata.makeTest(hash: "remote_version", vectorClock: remoteVC)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMeta),
            remoteState: .exists(remoteMeta),
            path: "concurrent.txt"
        )

        XCTAssertEqual(result, .conflict)
    }

    /// 场景：内容相同但 VectorClock 不同
    /// 预期：决策为 skip（哈希相同意味着内容一致）
    func testScenario_SameContent_DifferentVC_Skip() {
        let localVC = VectorClock.makeTest(["peerA": 2])
        let remoteVC = VectorClock.makeTest(["peerB": 2])

        let sameHash = "identical_content_hash"
        let localMeta = FileMetadata.makeTest(hash: sameHash, vectorClock: localVC)
        let remoteMeta = FileMetadata.makeTest(hash: sameHash, vectorClock: remoteVC)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMeta),
            remoteState: .exists(remoteMeta),
            path: "same_content.txt"
        )

        XCTAssertEqual(result, .skip)
    }

    // MARK: - Deletion Propagation Scenarios

    /// 场景：本地删除文件，远程仍存在（删除 VC 更新）
    /// 预期：决策为 deleteRemote
    func testScenario_LocalDelete_PropagatesRemote() {
        let deleteVC = VectorClock.makeTest(["peerA": 5])  // 删除时递增了
        let remoteVC = VectorClock.makeTest(["peerA": 2])  // 远程还是旧版本

        let localDel = DeletionRecord.makeTest(deletedBy: "peerA", vectorClock: deleteVC)
        let remoteMeta = FileMetadata.makeTest(hash: "old_content", vectorClock: remoteVC)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .deleted(localDel),
            remoteState: .exists(remoteMeta),
            path: "deleted_locally.txt"
        )

        XCTAssertEqual(result, .deleteRemote)
    }

    /// 场景：远程删除文件，本地仍存在（删除 VC 更新）
    /// 预期：决策为 deleteLocal
    func testScenario_RemoteDelete_PropagatesLocal() {
        let localVC = VectorClock.makeTest(["peerB": 2])  // 本地还是旧版本
        let deleteVC = VectorClock.makeTest(["peerB": 5])  // 删除时递增了

        let localMeta = FileMetadata.makeTest(hash: "old_content", vectorClock: localVC)
        let remoteDel = DeletionRecord.makeTest(deletedBy: "peerB", vectorClock: deleteVC)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMeta),
            remoteState: .deleted(remoteDel),
            path: "deleted_remotely.txt"
        )

        XCTAssertEqual(result, .deleteLocal)
    }

    /// 场景：双方都已删除
    /// 预期：决策为 skip
    func testScenario_BothDeleted_Skip() {
        let vcA = VectorClock.makeTest(["peerA": 2])
        let vcB = VectorClock.makeTest(["peerB": 2])

        let localDel = DeletionRecord.makeTest(deletedBy: "peerA", vectorClock: vcA)
        let remoteDel = DeletionRecord.makeTest(deletedBy: "peerB", vectorClock: vcB)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .deleted(localDel),
            remoteState: .deleted(remoteDel),
            path: "both_deleted.txt"
        )

        XCTAssertEqual(result, .skip)
    }

    // MARK: - File Resurrection Scenarios

    /// 场景：本地删除后，远程有更新版本（文件复活）
    /// 预期：决策为 download（远程复活了文件）
    func testScenario_LocalDelete_RemoteResurrect_Download() {
        let deleteVC = VectorClock.makeTest(["peerA": 2])
        let remoteVC = VectorClock.makeTest(["peerA": 2, "peerB": 3])  // 远程在删除后又更新了

        // 设置时间差，确保远程文件明显比删除更新
        let deleteTime = Date().addingTimeInterval(-10)
        let remoteMtime = Date()

        let localDel = DeletionRecord.makeTest(
            deletedAt: deleteTime,
            deletedBy: "peerA",
            vectorClock: deleteVC
        )
        let remoteMeta = FileMetadata.makeTest(
            hash: "resurrected",
            mtime: remoteMtime,
            vectorClock: remoteVC
        )

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .deleted(localDel),
            remoteState: .exists(remoteMeta),
            path: "resurrected.txt"
        )

        XCTAssertEqual(result, .download)
    }

    /// 场景：远程删除后，本地有更新版本（本地复活）
    /// 预期：决策为 upload（本地复活了文件）
    func testScenario_RemoteDelete_LocalResurrect_Upload() {
        let localVC = VectorClock.makeTest(["peerA": 1, "peerB": 5])  // 本地在删除后又更新了
        let deleteVC = VectorClock.makeTest(["peerA": 1, "peerB": 2])  // 删除时的版本

        // 设置时间差，确保本地文件明显比删除更新
        let deleteTime = Date().addingTimeInterval(-10)
        let localMtime = Date()

        let localMeta = FileMetadata.makeTest(
            hash: "local_resurrected",
            mtime: localMtime,
            vectorClock: localVC
        )
        let remoteDel = DeletionRecord.makeTest(
            deletedAt: deleteTime,
            deletedBy: "peerA",
            vectorClock: deleteVC
        )

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMeta),
            remoteState: .deleted(remoteDel),
            path: "local_resurrected.txt"
        )

        XCTAssertEqual(result, .upload)
    }

    // MARK: - Three-Client Scenarios

    /// 场景：A 创建文件，B 修改，C 同步
    /// C 持有原始版本，B 有修改版本 -> C 应该下载 B 的版本
    func testScenario_ThreeClients_CreateModifyReceive() {
        // A 创建文件
        let vcAfterCreate = VectorClock.makeTest(["peerA": 1])
        // B 收到后修改
        let vcAfterBModify = VectorClock.makeTest(["peerA": 1, "peerB": 1])

        let localMeta = FileMetadata.makeTest(hash: "original", vectorClock: vcAfterCreate)
        let remoteMeta = FileMetadata.makeTest(hash: "b_modified", vectorClock: vcAfterBModify)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMeta),
            remoteState: .exists(remoteMeta),
            path: "three_client.txt"
        )

        XCTAssertEqual(result, .download)
    }

    /// 场景：A 和 B 并发修改，C 检测冲突
    func testScenario_ThreeClients_ConcurrentModify_Conflict() {
        // A 和 B 都从初始状态修改
        let vcA = VectorClock.makeTest(["peerA": 2, "peerB": 1])  // A 修改了
        let vcB = VectorClock.makeTest(["peerA": 1, "peerB": 2])  // B 也修改了

        let localMeta = FileMetadata.makeTest(hash: "version_a", vectorClock: vcA)
        let remoteMeta = FileMetadata.makeTest(hash: "version_b", vectorClock: vcB)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMeta),
            remoteState: .exists(remoteMeta),
            path: "concurrent_three.txt"
        )

        XCTAssertEqual(result, .conflict)
    }

    // MARK: - Edge Cases

    /// 场景：双方都为 nil
    /// 预期：决策为 skip
    func testScenario_BothNil_Skip() {
        let result = SyncDecisionEngine.decideSyncAction(
            localState: nil,
            remoteState: nil,
            path: "nonexistent.txt"
        )

        XCTAssertEqual(result, .skip)
    }

    /// 场景：缺少 VectorClock
    /// 预期：决策为 uncertain
    func testScenario_MissingVectorClock_Uncertain() {
        let localMeta = FileMetadata.makeTest(hash: "local", vectorClock: nil)
        let remoteMeta = FileMetadata.makeTest(hash: "remote", vectorClock: nil)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMeta),
            remoteState: .exists(remoteMeta),
            path: "no_vc.txt"
        )

        XCTAssertEqual(result, .uncertain)
    }

    /// 场景：文件重命名 - 旧路径应被删除
    func testScenario_FileRename_OldPathDeleted() {
        let originalVC = VectorClock.makeTest(["peerA": 1])
        let deleteVC = VectorClock.makeTest(["peerA": 2])  // 重命名时旧路径被删除

        let localMeta = FileMetadata.makeTest(hash: "content", vectorClock: originalVC)
        let remoteDel = DeletionRecord.makeTest(deletedBy: "peerA", vectorClock: deleteVC)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMeta),
            remoteState: .deleted(remoteDel),
            path: "old_name.txt"
        )

        XCTAssertEqual(result, .deleteLocal)
    }

    /// 场景：文件重命名 - 新路径应被下载
    func testScenario_FileRename_NewPathDownloaded() {
        let vc = VectorClock.makeTest(["peerA": 2])  // 重命名后的新路径
        let remoteMeta = FileMetadata.makeTest(hash: "content", vectorClock: vc)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: nil,
            remoteState: .exists(remoteMeta),
            path: "new_name.txt"
        )

        XCTAssertEqual(result, .download)
    }
}
