import Foundation
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
    
    /// 在目录下用文件名或 NFD 形式查找文件并读取内容（macOS 文件名常为 NFD，与字面量 NFC 可能不一致）
    static func readFileContent(in directory: URL, filename: String) -> String? {
        let variants = [filename, filename.decomposedStringWithCanonicalMapping, filename.precomposedStringWithCanonicalMapping]
        for name in variants {
            let url = directory.appendingPathComponent(name)
            guard fileExists(at: url), let content = try? readFileContent(at: url) else { continue }
            return content
        }
        return nil
    }
    
    /// 在目录下是否存在内容为指定字符串的文件（不依赖路径，用于特殊字符文件名同步校验）
    static func hasFileWithContent(in directory: URL, content expectedContent: String) -> Bool {
        getFileContentByContentMatch(in: directory, content: expectedContent) != nil
    }

    /// 在目录下按内容查找文件并返回其内容（用于文件名编码不一致时的校验）
    static func getFileContentByContentMatch(in directory: URL, content expectedContent: String) -> String? {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles) else { return nil }
        for url in urls {
            var isRegular = false
            _ = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile.map { isRegular = $0 }
            guard isRegular, let content = try? readFileContent(at: url) else { continue }
            if content == expectedContent { return content }
        }
        return nil
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
    
    /// 等待条件满足（带超时，同步条件）
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

    /// 等待条件满足（带超时，异步条件，用于需 MainActor 等异步检查）
    static func waitForCondition(
        timeout: TimeInterval = 10.0,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        }
        return false
    }
    
    /// 等待同步完成（synced 或 error 时立即返回，否则轮询直至超时）
    static func waitForSyncCompletion(
        syncManager: SyncManager,
        folderID: UUID,
        timeout: TimeInterval = 30.0
    ) async -> Bool {
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            let done = await MainActor.run {
                guard let folder = syncManager.folders.first(where: { $0.id == folderID }) else { return false }
                return folder.status == .synced || folder.status == .error
            }
            if done {
                return await MainActor.run {
                    (syncManager.folders.first(where: { $0.id == folderID })).map { $0.status == .synced } ?? false
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
        }
        return await MainActor.run {
            (syncManager.folders.first(where: { $0.id == folderID })).map { $0.status == .synced } ?? false
        }
    }
    
    /// 显式触发同步并等待完成（用于不依赖 FSEvents 的测试）
    @MainActor
    static func triggerSyncAndWait(
        syncManager: SyncManager,
        folder: SyncFolder,
        timeout: TimeInterval = 30.0
    ) async -> Bool {
        syncManager.triggerSync(for: folder)
        return await waitForSyncCompletion(syncManager: syncManager, folderID: folder.id, timeout: timeout)
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
}
