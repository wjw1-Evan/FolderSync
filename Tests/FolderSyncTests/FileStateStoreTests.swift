import XCTest

@testable import FolderSync

/// FileStateStore 单元测试
/// 测试状态存储的核心功能
final class FileStateStoreTests: XCTestCase {

    var stateStore: FileStateStore!

    override func setUp() {
        super.setUp()
        stateStore = FileStateStore()
    }

    override func tearDown() {
        stateStore = nil
        super.tearDown()
    }

    // MARK: - Basic State Operations

    /// 测试设置文件存在状态
    func testSetExists_StoresMetadata() async throws {
        let metadata = FileMetadata.makeTest(
            hash: "abc123",
            vectorClock: .makeTest(["peerA": 1])
        )

        stateStore.setExists(path: "test.txt", metadata: metadata)

        // 等待异步写入完成
        try await Task.sleep(nanoseconds: 100_000_000)

        let state = stateStore.getState(for: "test.txt")
        XCTAssertNotNil(state)
        if case .exists(let storedMeta) = state {
            XCTAssertEqual(storedMeta.hash, "abc123")
        } else {
            XCTFail("State should be .exists")
        }
    }

    /// 测试设置文件删除状态
    func testSetDeleted_StoresDeletionRecord() async throws {
        let vc = VectorClock.makeTest(["peerA": 2])
        let record = DeletionRecord.makeTest(deletedBy: "peerA", vectorClock: vc)

        stateStore.setDeleted(path: "deleted.txt", record: record)

        try await Task.sleep(nanoseconds: 100_000_000)

        let state = stateStore.getState(for: "deleted.txt")
        XCTAssertNotNil(state)
        if case .deleted(let storedRecord) = state {
            XCTAssertEqual(storedRecord.deletedBy, "peerA")
        } else {
            XCTFail("State should be .deleted")
        }
    }

    /// 测试 isDeleted 方法
    func testIsDeleted_ReturnsCorrectValue() async throws {
        let vc = VectorClock.makeTest(["peerA": 1])
        let metadata = FileMetadata.makeTest(hash: "abc", vectorClock: vc)
        let record = DeletionRecord.makeTest(deletedBy: "peerA", vectorClock: vc)

        stateStore.setExists(path: "exists.txt", metadata: metadata)
        stateStore.setDeleted(path: "deleted.txt", record: record)

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(stateStore.isDeleted(path: "exists.txt"))
        XCTAssertTrue(stateStore.isDeleted(path: "deleted.txt"))
        XCTAssertFalse(stateStore.isDeleted(path: "nonexistent.txt"))
    }

    /// 测试获取所有已删除路径
    func testGetDeletedPaths_ReturnsOnlyDeleted() async throws {
        let vc = VectorClock.makeTest(["peerA": 1])
        let metadata = FileMetadata.makeTest(hash: "abc", vectorClock: vc)
        let record = DeletionRecord.makeTest(deletedBy: "peerA", vectorClock: vc)

        stateStore.setExists(path: "file1.txt", metadata: metadata)
        stateStore.setExists(path: "file2.txt", metadata: metadata)
        stateStore.setDeleted(path: "deleted1.txt", record: record)
        stateStore.setDeleted(path: "deleted2.txt", record: record)

        try await Task.sleep(nanoseconds: 100_000_000)

        let deletedPaths = stateStore.getDeletedPaths()
        XCTAssertEqual(deletedPaths.count, 2)
        XCTAssertTrue(deletedPaths.contains("deleted1.txt"))
        XCTAssertTrue(deletedPaths.contains("deleted2.txt"))
        XCTAssertFalse(deletedPaths.contains("file1.txt"))
    }

    /// 测试移除状态
    func testRemoveState_RemovesEntry() async throws {
        let vc = VectorClock.makeTest(["peerA": 1])
        let metadata = FileMetadata.makeTest(hash: "abc", vectorClock: vc)

        stateStore.setExists(path: "test.txt", metadata: metadata)

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(stateStore.getState(for: "test.txt"))

        stateStore.removeState(path: "test.txt")

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(stateStore.getState(for: "test.txt"))
    }

    /// 测试批量设置状态
    func testSetStates_MergesStates() async throws {
        let vc = VectorClock.makeTest(["peerA": 1])
        let metadata1 = FileMetadata.makeTest(hash: "hash1", vectorClock: vc)
        let metadata2 = FileMetadata.makeTest(hash: "hash2", vectorClock: vc)

        let states: [String: FileState] = [
            "file1.txt": .exists(metadata1),
            "file2.txt": .exists(metadata2),
        ]

        stateStore.setStates(states)

        try await Task.sleep(nanoseconds: 100_000_000)

        let allStates = stateStore.getAllStates()
        XCTAssertEqual(allStates.count, 2)
    }

    // MARK: - Thread Safety Tests

    /// 测试并发读写安全（简化版本）
    func testConcurrentAccess_NoRaceCondition() async throws {
        let iterations = 50

        // 并发写入
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let vc = VectorClock.makeTest(["peer": i])
                    let metadata = FileMetadata.makeTest(hash: "hash\(i)", vectorClock: vc)
                    self.stateStore.setExists(path: "file\(i).txt", metadata: metadata)
                }
            }
        }

        // 等待所有写入完成
        try await Task.sleep(nanoseconds: 500_000_000)

        // 并发读取
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    _ = self.stateStore.getState(for: "file\(i).txt")
                    _ = self.stateStore.isDeleted(path: "file\(i).txt")
                }
            }
        }

        // 验证状态一致
        let allStates = stateStore.getAllStates()
        XCTAssertEqual(allStates.count, iterations)
    }

    // MARK: - State Transition Tests

    /// 测试状态从存在变为删除
    func testStateTransition_ExistsToDeleted() async throws {
        let vc1 = VectorClock.makeTest(["peerA": 1])
        let metadata = FileMetadata.makeTest(hash: "content", vectorClock: vc1)

        stateStore.setExists(path: "file.txt", metadata: metadata)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(stateStore.isDeleted(path: "file.txt"))

        // 转变为删除状态
        let vc2 = VectorClock.makeTest(["peerA": 2])
        let record = DeletionRecord.makeTest(deletedBy: "peerA", vectorClock: vc2)
        stateStore.setDeleted(path: "file.txt", record: record)

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(stateStore.isDeleted(path: "file.txt"))
    }

    /// 测试状态从删除变为存在（复活）
    func testStateTransition_DeletedToExists() async throws {
        let vc1 = VectorClock.makeTest(["peerA": 1])
        let record = DeletionRecord.makeTest(deletedBy: "peerA", vectorClock: vc1)

        stateStore.setDeleted(path: "file.txt", record: record)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(stateStore.isDeleted(path: "file.txt"))

        // 转变为存在状态（复活）
        let vc2 = VectorClock.makeTest(["peerA": 2])
        let metadata = FileMetadata.makeTest(hash: "resurrected", vectorClock: vc2)
        stateStore.setExists(path: "file.txt", metadata: metadata)

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(stateStore.isDeleted(path: "file.txt"))
    }
}
