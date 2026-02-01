import XCTest

@testable import FolderSync

/// SyncDecisionEngine 集成测试
/// 测试实际文件操作与同步决策的集成
final class SyncDecisionEngineTests: XCTestCase {

    var testFolder: TestFolder!
    var stateStore: FileStateStore!
    let testFolderID = UUID()
    let testSyncID = "test-sync-id"
    let testPeerID = "testPeer"

    override func setUp() {
        super.setUp()
        testFolder = try? TestFolder()
        stateStore = FileStateStore()
    }

    override func tearDown() {
        testFolder = nil
        stateStore = nil
        super.tearDown()
    }

    // MARK: - File Creation Integration Tests

    /// 测试创建新文件后，决策引擎正确识别为需要上传（对远程而言）
    func testFileCreation_NewFileUncertain() async throws {
        // 创建一个新文件
        let fileURL = try testFolder.createFile("new_file.txt", content: "Hello, World!")

        await waitForFileSystem()

        // 计算文件哈希和元数据
        guard let hash = computeFileHash(at: fileURL) else {
            XCTFail("Failed to compute file hash")
            return
        }

        // 创建本地文件状态（模拟本地新建的文件）
        let vc = VectorClock.makeTest([testPeerID: 1])
        let localMeta = FileMetadata.makeTest(hash: hash, vectorClock: vc)

        // 远程不存在此文件
        let result = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMeta),
            remoteState: nil,
            path: "new_file.txt"
        )

        // 本地存在但远程无状态时返回 uncertain（需要检查是否有删除记录）
        XCTAssertEqual(result, .uncertain)
    }

    /// 测试当远程有新文件时，决策引擎正确识别为需要下载
    func testRemoteFileExists_LocalNotExists_Download() async throws {
        // 本地不存在文件
        XCTAssertFalse(testFolder.fileExists("remote_file.txt"))

        // 模拟远程存在文件
        let remoteVC = VectorClock.makeTest(["remotePeer": 1])
        let remoteMeta = FileMetadata.makeTest(hash: "remote_hash", vectorClock: remoteVC)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: nil,
            remoteState: .exists(remoteMeta),
            path: "remote_file.txt"
        )

        XCTAssertEqual(result, .download)
    }

    // MARK: - File Modification Integration Tests

    /// 测试文件内容变化后，哈希值变化导致正确的同步决策
    func testFileModification_HashChange_TriggersSync() async throws {
        // 创建初始文件
        _ = try testFolder.createFile("modify_test.txt", content: "Initial content")
        await waitForFileSystem()

        // 模拟本地和远程都有文件，但本地已修改（VC 更新）
        let localVC = VectorClock.makeTest([testPeerID: 2])  // 本地版本更新
        let remoteVC = VectorClock.makeTest([testPeerID: 1])

        let localMeta = FileMetadata.makeTest(hash: "modified_hash", vectorClock: localVC)
        let remoteMeta = FileMetadata.makeTest(hash: "original_hash", vectorClock: remoteVC)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMeta),
            remoteState: .exists(remoteMeta),
            path: "modify_test.txt"
        )

        // 本地版本更新，应该上传
        XCTAssertEqual(result, .upload)
    }

    /// 测试同样内容的文件（哈希相同）跳过同步
    func testSameContent_Skip() async throws {
        let content = "Same content"
        _ = try testFolder.createFile("same_content.txt", content: content)
        await waitForFileSystem()

        let sameHash = "identical_hash"
        let localVC = VectorClock.makeTest([testPeerID: 1])
        let remoteVC = VectorClock.makeTest(["remotePeer": 1])

        let localMeta = FileMetadata.makeTest(hash: sameHash, vectorClock: localVC)
        let remoteMeta = FileMetadata.makeTest(hash: sameHash, vectorClock: remoteVC)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMeta),
            remoteState: .exists(remoteMeta),
            path: "same_content.txt"
        )

        // 哈希相同，跳过
        XCTAssertEqual(result, .skip)
    }

    // MARK: - File Deletion Integration Tests

    /// 测试本地删除文件后，决策引擎正确处理删除传播
    func testFileDeletion_DeleteRemote() async throws {
        // 创建文件然后删除
        _ = try testFolder.createFile("to_delete.txt", content: "Will be deleted")
        await waitForFileSystem()
        try testFolder.deleteFile("to_delete.txt")
        await waitForFileSystem()

        XCTAssertFalse(testFolder.fileExists("to_delete.txt"))

        // 创建删除记录（VC 递增）
        let deleteVC = VectorClock.makeTest([testPeerID: 2])
        let deletionRecord = DeletionRecord.makeTest(deletedBy: testPeerID, vectorClock: deleteVC)

        // 远程仍有旧版本
        let remoteVC = VectorClock.makeTest([testPeerID: 1])
        let remoteMeta = FileMetadata.makeTest(hash: "old_content", vectorClock: remoteVC)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .deleted(deletionRecord),
            remoteState: .exists(remoteMeta),
            path: "to_delete.txt"
        )

        // 删除 VC 更新，应该删除远程
        XCTAssertEqual(result, .deleteRemote)
    }

    /// 测试远程删除传播到本地
    func testRemoteDeletion_DeleteLocal() async throws {
        // 本地有文件
        _ = try testFolder.createFile("remote_deleted.txt", content: "Exists locally")
        await waitForFileSystem()
        XCTAssertTrue(testFolder.fileExists("remote_deleted.txt"))

        // 本地文件状态
        let localVC = VectorClock.makeTest([testPeerID: 1])
        let localMeta = FileMetadata.makeTest(hash: "local_content", vectorClock: localVC)

        // 远程删除记录（VC 更新）
        let deleteVC = VectorClock.makeTest([testPeerID: 2])
        let remoteDel = DeletionRecord.makeTest(deletedBy: "remotePeer", vectorClock: deleteVC)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMeta),
            remoteState: .deleted(remoteDel),
            path: "remote_deleted.txt"
        )

        // 远程删除 VC 更新，应该删除本地
        XCTAssertEqual(result, .deleteLocal)
    }

    // MARK: - File Rename Integration Tests

    /// 测试文件重命名场景：旧路径被删除
    func testFileRename_OldPathDeleted() async throws {
        // 创建文件然后重命名
        _ = try testFolder.createFile("old_name.txt", content: "Renamed file")
        await waitForFileSystem()
        try testFolder.renameFile(from: "old_name.txt", to: "new_name.txt")
        await waitForFileSystem()

        XCTAssertFalse(testFolder.fileExists("old_name.txt"))
        XCTAssertTrue(testFolder.fileExists("new_name.txt"))

        // 旧路径的删除记录
        let deleteVC = VectorClock.makeTest([testPeerID: 2])
        let deletionRecord = DeletionRecord.makeTest(deletedBy: testPeerID, vectorClock: deleteVC)

        // 远程仍有旧路径
        let remoteVC = VectorClock.makeTest([testPeerID: 1])
        let remoteMeta = FileMetadata.makeTest(hash: "content", vectorClock: remoteVC)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .deleted(deletionRecord),
            remoteState: .exists(remoteMeta),
            path: "old_name.txt"
        )

        XCTAssertEqual(result, .deleteRemote)
    }

    /// 测试文件重命名场景：新路径被同步
    func testFileRename_NewPathSynced() async throws {
        // 本地有新路径
        _ = try testFolder.createFile("new_name.txt", content: "Renamed file")
        await waitForFileSystem()

        guard let hash = computeFileHash(at: testFolder.url.appendingPathComponent("new_name.txt"))
        else {
            XCTFail("Failed to compute hash")
            return
        }

        let localVC = VectorClock.makeTest([testPeerID: 2])
        let localMeta = FileMetadata.makeTest(hash: hash, vectorClock: localVC)

        // 远程没有新路径
        let result = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMeta),
            remoteState: nil,
            path: "new_name.txt"
        )

        // 返回 uncertain（需要检查是否有删除记录）
        XCTAssertEqual(result, .uncertain)
    }

    // MARK: - Conflict Detection Integration Tests

    /// 测试并发修改检测
    func testConcurrentModification_Conflict() async throws {
        // 本地和远程都有修改，且 VectorClock 并发
        let localVC = VectorClock.makeTest([testPeerID: 2, "remotePeer": 1])
        let remoteVC = VectorClock.makeTest([testPeerID: 1, "remotePeer": 2])

        let localMeta = FileMetadata.makeTest(hash: "local_version", vectorClock: localVC)
        let remoteMeta = FileMetadata.makeTest(hash: "remote_version", vectorClock: remoteVC)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: .exists(localMeta),
            remoteState: .exists(remoteMeta),
            path: "conflict.txt"
        )

        XCTAssertEqual(result, .conflict)
    }

    // MARK: - State Store Integration Tests

    /// 测试状态存储与决策引擎的集成
    func testStateStore_Integration() async throws {
        // 设置本地文件状态
        let localVC = VectorClock.makeTest([testPeerID: 1])
        let localMeta = FileMetadata.makeTest(hash: "content", vectorClock: localVC)
        stateStore.setExists(path: "test.txt", metadata: localMeta)

        await waitForFileSystem()

        // 从状态存储获取状态
        let storedState = stateStore.getState(for: "test.txt")
        XCTAssertNotNil(storedState)

        // 模拟远程更新
        let remoteVC = VectorClock.makeTest([testPeerID: 2])
        let remoteMeta = FileMetadata.makeTest(hash: "updated_content", vectorClock: remoteVC)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: storedState,
            remoteState: .exists(remoteMeta),
            path: "test.txt"
        )

        // 远程版本更新，应该下载
        XCTAssertEqual(result, .download)
    }

    /// 测试删除状态存储与决策引擎的集成
    func testDeletedStateStore_Integration() async throws {
        // 设置删除记录
        let deleteVC = VectorClock.makeTest([testPeerID: 2])
        let deletionRecord = DeletionRecord.makeTest(deletedBy: testPeerID, vectorClock: deleteVC)
        stateStore.setDeleted(path: "deleted.txt", record: deletionRecord)

        await waitForFileSystem()

        XCTAssertTrue(stateStore.isDeleted(path: "deleted.txt"))

        let storedState = stateStore.getState(for: "deleted.txt")

        // 远程有旧版本
        let remoteVC = VectorClock.makeTest([testPeerID: 1])
        let remoteMeta = FileMetadata.makeTest(hash: "old", vectorClock: remoteVC)

        let result = SyncDecisionEngine.decideSyncAction(
            localState: storedState,
            remoteState: .exists(remoteMeta),
            path: "deleted.txt"
        )

        XCTAssertEqual(result, .deleteRemote)
    }
}
