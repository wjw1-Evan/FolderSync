import Foundation
import XCTest
@testable import FolderSync

/// 测试辅助工具类
class TestHelpers {
    /// 创建临时测试目录
    static func createTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let testDir = tempDir.appendingPathComponent("FolderSyncTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        return testDir
    }
    
    /// 清理临时目录
    static func cleanupTempDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
    
    /// 创建测试文件
    static func createTestFile(at url: URL, content: String = "test content") throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
    
    /// 创建测试文件（二进制数据）
    static func createTestFile(at url: URL, data: Data) throws {
        try data.write(to: url)
    }
    
    /// 创建测试文件夹及其内容
    static func createTestFolder(at url: URL, files: [String: String]) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (relativePath, content) in files {
            let fileURL = url.appendingPathComponent(relativePath)
            let parentDir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try createTestFile(at: fileURL, content: content)
        }
    }
    
    /// 读取文件内容
    static func readFileContent(at url: URL) throws -> String {
        return try String(contentsOf: url, encoding: .utf8)
    }
    
    /// 读取文件数据
    static func readFileData(at url: URL) throws -> Data {
        return try Data(contentsOf: url)
    }
    
    /// 检查文件是否存在
    static func fileExists(at url: URL) -> Bool {
        return FileManager.default.fileExists(atPath: url.path)
    }
    
    /// 检查目录是否存在
    static func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
    
    /// 获取目录中的所有文件
    static func getAllFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
               resourceValues.isRegularFile == true {
                files.append(fileURL)
            }
        }
        return files
    }
    
    /// 等待条件满足（带超时）
    static func waitForCondition(
        timeout: TimeInterval = 10.0,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        }
        return false
    }
    
    /// 等待 P2P 节点启动（检查节点是否已准备好）
    @MainActor
    static func waitForP2PNodeReady(
        syncManager: SyncManager,
        timeout: TimeInterval = 10.0
    ) async -> Bool {
        return await waitForCondition(timeout: timeout) {
            syncManager.p2pNode.peerID != nil
        }
    }
    
    /// 等待 peer 发现（检查是否有其他 peer）
    @MainActor
    static func waitForPeerDiscovery(
        syncManager: SyncManager,
        expectedCount: Int = 1,
        timeout: TimeInterval = 15.0
    ) async -> Bool {
        return await waitForCondition(timeout: timeout) {
            syncManager.peerManager.allPeers.count >= expectedCount
        }
    }
    
    /// 等待同步完成
    static func waitForSyncCompletion(
        syncManager: SyncManager,
        folderID: UUID,
        timeout: TimeInterval = 30.0
    ) async -> Bool {
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            await MainActor.run {
                if let folder = syncManager.folders.first(where: { $0.id == folderID }) {
                    if folder.status == .synced || folder.status == .error {
                        return
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
        }
        
        // 最后检查一次状态
        return await MainActor.run {
            if let folder = syncManager.folders.first(where: { $0.id == folderID }) {
                return folder.status == .synced
            }
            return false
        }
    }
    
    /// 创建测试用的 SyncFolder
    static func createTestSyncFolder(
        syncID: String = "test\(UUID().uuidString.prefix(8))",
        localPath: URL,
        mode: SyncMode = .twoWay
    ) -> SyncFolder {
        return SyncFolder(
            syncID: syncID,
            localPath: localPath,
            mode: mode,
            status: .synced,
            excludePatterns: []
        )
    }
    
    /// 生成大文件数据（用于测试块级同步）
    static func generateLargeFileData(sizeInMB: Int) -> Data {
        let sizeInBytes = sizeInMB * 1024 * 1024
        var data = Data()
        let chunkSize = 1024
        let chunk = Data(repeating: UInt8.random(in: 0...255), count: chunkSize)
        
        for _ in 0..<(sizeInBytes / chunkSize) {
            data.append(chunk)
        }
        
        // 添加剩余字节
        let remainder = sizeInBytes % chunkSize
        if remainder > 0 {
            data.append(Data(repeating: UInt8.random(in: 0...255), count: remainder))
        }
        
        return data
    }
    
    /// 比较两个目录的内容是否一致
    static func compareDirectories(_ dir1: URL, _ dir2: URL) -> Bool {
        let files1 = getAllFiles(in: dir1)
        let files2 = getAllFiles(in: dir2)
        
        guard files1.count == files2.count else {
            return false
        }
        
        for file1 in files1 {
            let relativePath = file1.path.replacingOccurrences(of: dir1.path + "/", with: "")
            let file2 = dir2.appendingPathComponent(relativePath)
            
            guard fileExists(at: file2) else {
                return false
            }
            
            do {
                let data1 = try readFileData(at: file1)
                let data2 = try readFileData(at: file2)
                guard data1 == data2 else {
                    return false
                }
            } catch {
                return false
            }
        }
        
        return true
    }
    
    /// 获取文件的相对路径（相对于基础目录）
    static func getRelativePath(_ fileURL: URL, baseDirectory: URL) -> String {
        let basePath = baseDirectory.path
        let filePath = fileURL.path
        guard filePath.hasPrefix(basePath) else {
            return filePath
        }
        var relativePath = String(filePath.dropFirst(basePath.count))
        if relativePath.hasPrefix("/") {
            relativePath = String(relativePath.dropFirst())
        }
        return relativePath
    }
}

/// Mock P2P 节点 - 用于测试
class MockP2PNode {
    var peerID: PeerID?
    var isOnline: Bool = true
    var shouldFailRequests: Bool = false
    var requestDelay: TimeInterval = 0.0
    
    init(peerID: PeerID? = nil) {
        self.peerID = peerID ?? PeerID.generate()
    }
    
    func setOnline(_ online: Bool) {
        isOnline = online
    }
    
    func setRequestFailure(_ shouldFail: Bool) {
        shouldFailRequests = shouldFail
    }
    
    func setRequestDelay(_ delay: TimeInterval) {
        requestDelay = delay
    }
}

/// 测试用的网络服务 Mock
class MockNetworkService {
    var isConnected: Bool = true
    var shouldSimulateNetworkFailure: Bool = false
    var networkDelay: TimeInterval = 0.0
    
    func setConnected(_ connected: Bool) {
        isConnected = connected
    }
    
    func simulateNetworkFailure(_ shouldFail: Bool) {
        shouldSimulateNetworkFailure = shouldFail
    }
    
    func setNetworkDelay(_ delay: TimeInterval) {
        networkDelay = delay
    }
}

/// 测试扩展 - 用于 XCTest
extension XCTestCase {
    /// 创建临时目录并在测试后清理
    func withTempDirectory(_ block: (URL) throws -> Void) rethrows {
        let tempDir = try! TestHelpers.createTempDirectory()
        defer {
            TestHelpers.cleanupTempDirectory(tempDir)
        }
        try block(tempDir)
    }
    
    /// 等待异步操作完成
    func waitForAsync(timeout: TimeInterval = 10.0, _ block: @escaping () async -> Bool) async throws {
        let expectation = expectation(description: "Async operation")
        var result = false
        
        Task {
            result = await block()
            expectation.fulfill()
        }
        
        await fulfillment(of: [expectation], timeout: timeout)
        XCTAssertTrue(result, "异步操作未在超时时间内完成")
    }
    
    /// 等待条件满足
    func waitForCondition(
        timeout: TimeInterval = 10.0,
        condition: @escaping () -> Bool
    ) async throws {
        let satisfied = await TestHelpers.waitForCondition(timeout: timeout, condition: condition)
        XCTAssertTrue(satisfied, "条件未在超时时间内满足")
    }
}
