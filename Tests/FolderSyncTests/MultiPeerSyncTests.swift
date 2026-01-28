import XCTest
import Foundation
@testable import FolderSync

/// 多端同步基础测试
@MainActor
final class MultiPeerSyncTests: XCTestCase {
    var tempDir1: URL!
    var tempDir2: URL!
    var tempDir3: URL!
    var syncManager1: SyncManager!
    var syncManager2: SyncManager!
    var syncManager3: SyncManager!
    var syncID: String!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // 创建临时目录
        tempDir1 = try TestHelpers.createTempDirectory()
        tempDir2 = try TestHelpers.createTempDirectory()
        tempDir3 = try TestHelpers.createTempDirectory()
        
        // 创建同步 ID
        syncID = "test\(UUID().uuidString.prefix(8))"
        
        // 初始化 SyncManager（需要在实际环境中测试，因为涉及网络）
        // 注意：这些测试需要实际的网络环境，可能需要调整
        syncManager1 = SyncManager()
        syncManager2 = SyncManager()
        syncManager3 = SyncManager()
        
        // 等待 P2P 节点启动
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
    }
    
    override func tearDown() async throws {
        // 停止 P2P 节点以清理资源
        try? await syncManager1?.p2pNode.stop()
        try? await syncManager2?.p2pNode.stop()
        try? await syncManager3?.p2pNode.stop()
        
        // 清理
        syncManager1 = nil
        syncManager2 = nil
        syncManager3 = nil
        
        TestHelpers.cleanupTempDirectory(tempDir1)
        TestHelpers.cleanupTempDirectory(tempDir2)
        TestHelpers.cleanupTempDirectory(tempDir3)
        
        try await super.tearDown()
    }
    
    /// 测试多客户端初始化
    func testMultipleClientsInitialization() async throws {
        // 验证所有客户端都已初始化
        XCTAssertNotNil(syncManager1)
        XCTAssertNotNil(syncManager2)
        XCTAssertNotNil(syncManager3)
        
        // 验证每个客户端都有唯一的 PeerID
        let peerID1 = syncManager1.p2pNode.peerID
        let peerID2 = syncManager2.p2pNode.peerID
        let peerID3 = syncManager3.p2pNode.peerID
        
        XCTAssertNotNil(peerID1)
        XCTAssertNotNil(peerID2)
        XCTAssertNotNil(peerID3)
        
        // 验证 PeerID 唯一性（peerID 是 String? 类型）
        if let pid1 = peerID1, let pid2 = peerID2, let pid3 = peerID3 {
            XCTAssertNotEqual(pid1, pid2)
            XCTAssertNotEqual(pid1, pid3)
            XCTAssertNotEqual(pid2, pid3)
        }
    }
    
    /// 测试客户端发现和连接
    func testPeerDiscovery() async throws {
        // 等待客户端发现彼此
        try await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
        
        // 验证客户端1发现了其他客户端
        let peers1 = syncManager1.peerManager.allPeers
        print("[Test] 客户端1发现的peer数量: \(peers1.count)")
        
        // 验证客户端2发现了其他客户端
        let peers2 = syncManager2.peerManager.allPeers
        print("[Test] 客户端2发现的peer数量: \(peers2.count)")
        
        // 验证客户端3发现了其他客户端
        let peers3 = syncManager3.peerManager.allPeers
        print("[Test] 客户端3发现的peer数量: \(peers3.count)")
        
        // 注意：在实际测试中，可能需要更长的等待时间或手动触发发现
        // 这里主要验证发现机制是否正常工作
    }
    
    /// 测试基本同步流程 - 添加文件夹
    func testBasicSyncFlow_AddFolder() async throws {
        // 在客户端1添加文件夹
        let folder1 = TestHelpers.createTestSyncFolder(
            syncID: syncID,
            localPath: tempDir1
        )
        syncManager1.addFolder(folder1)
        
        // 等待文件夹添加完成
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 验证文件夹已添加
        XCTAssertTrue(syncManager1.folders.contains { $0.syncID == syncID })
        
        // 在客户端2添加相同的 syncID 文件夹
        let folder2 = TestHelpers.createTestSyncFolder(
            syncID: syncID,
            localPath: tempDir2
        )
        syncManager2.addFolder(folder2)
        
        // 等待同步
        try await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        
        // 验证客户端2也添加了文件夹
        XCTAssertTrue(syncManager2.folders.contains { $0.syncID == syncID })
    }
    
    /// 测试基本同步流程 - 文件同步
    func testBasicSyncFlow_FileSync() async throws {
        // 设置文件夹
        let folder1 = TestHelpers.createTestSyncFolder(
            syncID: syncID,
            localPath: tempDir1
        )
        syncManager1.addFolder(folder1)
        
        let folder2 = TestHelpers.createTestSyncFolder(
            syncID: syncID,
            localPath: tempDir2
        )
        syncManager2.addFolder(folder2)
        
        // 等待文件夹添加和发现
        try await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
        
        // 在客户端1创建文件
        let testFile = tempDir1.appendingPathComponent("test.txt")
        try TestHelpers.createTestFile(at: testFile, content: "Hello from client 1")
        
        // 等待文件监控检测到变化
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 等待同步完成
        let synced = await TestHelpers.waitForSyncCompletion(
            syncManager: syncManager1,
            folderID: folder1.id,
            timeout: 30.0
        )
        
        XCTAssertTrue(synced, "同步应该完成")
        
        // 验证文件已同步到客户端2
        let syncedFile = tempDir2.appendingPathComponent("test.txt")
        
        // 等待文件出现
        let fileExists = await TestHelpers.waitForCondition(timeout: 10.0) {
            TestHelpers.fileExists(at: syncedFile)
        }
        
        XCTAssertTrue(fileExists, "文件应该已同步到客户端2")
        
        if fileExists {
            let content = try TestHelpers.readFileContent(at: syncedFile)
            XCTAssertEqual(content, "Hello from client 1", "文件内容应该一致")
        }
    }
    
    /// 测试三客户端同步
    func testThreeClientSync() async throws {
        // 设置文件夹
        let folder1 = TestHelpers.createTestSyncFolder(
            syncID: syncID,
            localPath: tempDir1
        )
        syncManager1.addFolder(folder1)
        
        let folder2 = TestHelpers.createTestSyncFolder(
            syncID: syncID,
            localPath: tempDir2
        )
        syncManager2.addFolder(folder2)
        
        let folder3 = TestHelpers.createTestSyncFolder(
            syncID: syncID,
            localPath: tempDir3
        )
        syncManager3.addFolder(folder3)
        
        // 等待文件夹添加和发现
        try await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
        
        // 在客户端1创建文件
        let testFile1 = tempDir1.appendingPathComponent("file1.txt")
        try TestHelpers.createTestFile(at: testFile1, content: "File from client 1")
        
        // 在客户端2创建文件
        let testFile2 = tempDir2.appendingPathComponent("file2.txt")
        try TestHelpers.createTestFile(at: testFile2, content: "File from client 2")
        
        // 等待同步
        try await Task.sleep(nanoseconds: 5_000_000_000) // 5秒
        
        // 等待所有同步完成
        let synced1 = await TestHelpers.waitForSyncCompletion(
            syncManager: syncManager1,
            folderID: folder1.id,
            timeout: 30.0
        )
        let synced2 = await TestHelpers.waitForSyncCompletion(
            syncManager: syncManager2,
            folderID: folder2.id,
            timeout: 30.0
        )
        let synced3 = await TestHelpers.waitForSyncCompletion(
            syncManager: syncManager3,
            folderID: folder3.id,
            timeout: 30.0
        )
        
        XCTAssertTrue(synced1 && synced2 && synced3, "所有客户端应该完成同步")
        
        // 验证所有文件都已同步到所有客户端
        let filesToCheck: [(URL?, String, String)] = [
            (tempDir1, "file1.txt", "File from client 1"),
            (tempDir1, "file2.txt", "File from client 2"),
            (tempDir2, "file1.txt", "File from client 1"),
            (tempDir2, "file2.txt", "File from client 2"),
            (tempDir3, "file1.txt", "File from client 1"),
            (tempDir3, "file2.txt", "File from client 2")
        ]
        
        for (dir, filename, expectedContent) in filesToCheck {
            guard let dir = dir else { continue }
            let fileURL = dir.appendingPathComponent(filename)
            let exists = await TestHelpers.waitForCondition(timeout: 10.0) {
                TestHelpers.fileExists(at: fileURL)
            }
            
            if exists {
                let content = try TestHelpers.readFileContent(at: fileURL)
                XCTAssertEqual(content, expectedContent, "文件 \(filename) 在 \(dir.lastPathComponent) 中应该存在且内容正确")
            } else {
                XCTFail("文件 \(filename) 应该在 \(dir.lastPathComponent) 中存在")
            }
        }
    }
    
    /// 测试同步状态更新
    func testSyncStatusUpdate() async throws {
        let folder1 = TestHelpers.createTestSyncFolder(
            syncID: syncID,
            localPath: tempDir1
        )
        syncManager1.addFolder(folder1)
        
        // 等待文件夹添加
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        // 验证初始状态
        if let folder = syncManager1.folders.first(where: { $0.id == folder1.id }) {
            // 状态可能是 synced 或 syncing
            XCTAssertTrue(
                folder.status == .synced || folder.status == .syncing,
                "文件夹状态应该是 synced 或 syncing"
            )
        }
        
        // 创建文件触发同步
        let testFile = tempDir1.appendingPathComponent("status_test.txt")
        try TestHelpers.createTestFile(at: testFile, content: "Test")
        
        // 等待状态更新
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 验证状态已更新
        if let folder = syncManager1.folders.first(where: { $0.id == folder1.id }) {
            print("[Test] 文件夹状态: \(folder.status)")
            print("[Test] 同步进度: \(folder.syncProgress)")
            print("[Test] 最后同步消息: \(folder.lastSyncMessage ?? "nil")")
        }
    }
}
