import Foundation
import XCTest

@testable import FolderSync

/// 精细化的删除逻辑测试，包括文件复活（Resurrection）和并发删除冲突
@MainActor
final class RefinedDeletionTests: TwoClientTestCase {

    /// 确保双方已连接
    func ensurePeersConnected() async throws {
        // 显式解包 PeerID，避免编译器类型推断错误
        guard let p1Info = self.syncManager1.p2pNode.peerID,
            let p2Info = self.syncManager2.p2pNode.peerID
        else {
            XCTFail("PeerID 未初始化")
            return
        }

        // 使用 b58String 属性（String 类型）
        let p1ID = p1Info.b58String
        let p2ID = p2Info.b58String

        // 等待双方都看到对方在线
        let connected = await TestHelpers.waitForCondition(timeout: 10.0) {
            // 检查 PeerManager 状态，注意闭包中的类型匹配
            let p1SeesP2 = self.syncManager1.peerManager.allPeers.contains { peer in
                peer.peerID.b58String == p2ID && peer.isOnline
            }
            let p2SeesP1 = self.syncManager2.peerManager.allPeers.contains { peer in
                peer.peerID.b58String == p1ID && peer.isOnline
            }
            return p1SeesP2 && p2SeesP1
        }

        if !connected {
            // 如果连接失败，尝试重新触发连接
            // 使用 public func connect(to peerID: PeerID)
            try? await self.syncManager1.p2pNode.connect(to: p2Info)
            try? await self.syncManager2.p2pNode.connect(to: p1Info)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// 测试文件复活：删除文件后立即重新创建，验证对端不会误删
    func testFileResurrection() async throws {
        try await ensurePeersConnected()

        let filename = "resurrect_me.txt"
        let fileURL1 = tempDir1.appendingPathComponent(filename)
        let fileURL2 = tempDir2.appendingPathComponent(filename)

        // 1. 初始创建并同步
        try TestHelpers.createTestFile(at: fileURL1, content: "Version 1")
        try? await Task.sleep(nanoseconds: 2_000_000_000)  // 等待同步

        let existsV1 = await TestHelpers.waitForCondition(timeout: 10.0) {
            TestHelpers.fileExists(at: fileURL2)
        }
        XCTAssertTrue(existsV1, "初始文件应同步")

        // 2. 删除文件 (Peer 1)
        try FileManager.default.removeItem(at: fileURL1)

        // 确保删除被记录并开始同步 (等待 Peer 2 也删除)
        // 注意：为了模拟“复活”时的竞态，我们希望在 Peer 2 收到删除信号的同时（或之后），Peer 1 已经有了新文件
        // 这里先让它们完全同步删除状态，模拟最简单的复活场景
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let deletedV1 = await TestHelpers.waitForCondition(timeout: 10.0) {
            !TestHelpers.fileExists(at: fileURL2)
        }
        XCTAssertTrue(deletedV1, "文件删除应同步")

        // 3. 重新创建文件 (Peer 1) - 复活
        // 关键点：确保 mtime 比之前的删除时间晚
        try? await Task.sleep(nanoseconds: 1_200_000_000)  // 等待超过 1.0 秒，确保 mtime 差异明显
        try TestHelpers.createTestFile(at: fileURL1, content: "Version 2 (Resurrected)")

        // 4. 等待同步
        // 之前有 Bug 的时候，SyncEngine 可能会看到远程的删除记录，认为本地的新文件是旧文件而误删
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        // 5. 验证文件存在且未被删除
        let existsV2 = await TestHelpers.waitForCondition(timeout: 10.0) {
            guard TestHelpers.fileExists(at: fileURL2) else { return false }
            let content = try? TestHelpers.readFileContent(at: fileURL2)
            return content == "Version 2 (Resurrected)"
        }

        XCTAssertTrue(existsV2, "复活的文件应该同步到对端，而不是被删除")

        // 双向验证：确保 Peer 1 的文件也没有被反向同步删除
        XCTAssertTrue(TestHelpers.fileExists(at: fileURL1), "本地复活的文件不应被误删")
    }

    /// 测试并发场景：一边删除，一边更新（更新者获胜）
    func testConcurrentDeletionAndModification_ResurrectionWins() async throws {
        try await ensurePeersConnected()

        let filename = "concurrent_conflict.txt"
        let fileURL1 = tempDir1.appendingPathComponent(filename)
        let fileURL2 = tempDir2.appendingPathComponent(filename)

        // 1. 初始同步
        try TestHelpers.createTestFile(at: fileURL1, content: "Base Version")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertTrue(TestHelpers.fileExists(at: fileURL2))

        // 暂停同步（模拟网络断开或高延迟，以便制造并发）
        // 这里我们通过快速操作来尝试制造并发，或者依靠 TwoClientTestCase 的机制
        // 由于无法直接暂停 SyncEngine，我们连续快速执行操作

        // 2. Peer 1 删除文件
        try FileManager.default.removeItem(at: fileURL1)

        // 3. Peer 2 修改文件 (几乎同时)
        // 确保修改时间晚于删除操作一点点，或者利用逻辑中的 "Local update wins over remote deletion"
        try? await Task.sleep(nanoseconds: 1_500_000_000)  // 等待 > 1s 以触发 "Local file is newer than deletion" 逻辑
        try TestHelpers.createTestFile(at: fileURL2, content: "Modified Version")

        // 4. 等待同步收敛
        try? await Task.sleep(nanoseconds: 5_000_000_000)

        // 5. 预期结果：Peer 2 的修改应该传播回 Peer 1（文件复活/保留）
        // 因为 Peer 2 检测到远程（Peer 1）删除了文件，但本地（Peer 2）有更新的版本（mtime updated），
        // 根据新的决策逻辑，应该判定为 Upload，将文件推回给 Peer 1。

        let file1Restored = await TestHelpers.waitForCondition(timeout: 10.0) {
            TestHelpers.fileExists(at: fileURL1)
        }

        let file2Exists = TestHelpers.fileExists(at: fileURL2)

        XCTAssertTrue(file2Exists, "Peer 2 的文件应保留")
        XCTAssertTrue(file1Restored, "Peer 1 应该接收 Peer 2 的修改（文件被恢复）")

        if file1Restored {
            let content = try? TestHelpers.readFileContent(at: fileURL1)
            XCTAssertEqual(content, "Modified Version")
        }
    }
}
