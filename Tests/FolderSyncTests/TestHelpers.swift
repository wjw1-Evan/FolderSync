import Crypto
import Foundation
import XCTest

@testable import FolderSync

// MARK: - Test Folder Helper

/// 临时测试文件夹管理器
class TestFolder {
    let url: URL
    let fileManager = FileManager.default

    init(name: String = "TestFolder-\(UUID().uuidString)") throws {
        let tempDir = FileManager.default.temporaryDirectory
        url = tempDir.appendingPathComponent(name)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? fileManager.removeItem(at: url)
    }

    /// 创建测试文件
    func createFile(_ name: String, content: String = "test content") throws -> URL {
        let fileURL = url.appendingPathComponent(name)
        // 创建父目录（如果需要）
        let parentDir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// 修改测试文件
    func modifyFile(_ name: String, content: String) throws {
        let fileURL = url.appendingPathComponent(name)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// 删除测试文件
    func deleteFile(_ name: String) throws {
        let fileURL = url.appendingPathComponent(name)
        try fileManager.removeItem(at: fileURL)
    }

    /// 重命名测试文件
    func renameFile(from oldName: String, to newName: String) throws {
        let oldURL = url.appendingPathComponent(oldName)
        let newURL = url.appendingPathComponent(newName)
        try fileManager.moveItem(at: oldURL, to: newURL)
    }

    /// 检查文件是否存在
    func fileExists(_ name: String) -> Bool {
        let fileURL = url.appendingPathComponent(name)
        return fileManager.fileExists(atPath: fileURL.path)
    }

    /// 读取文件内容
    func readFile(_ name: String) throws -> String {
        let fileURL = url.appendingPathComponent(name)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}

// MARK: - FileMetadata Helper

extension FileMetadata {
    /// 创建测试用 FileMetadata
    static func makeTest(
        hash: String,
        mtime: Date = Date(),
        vectorClock: VectorClock? = nil,
        isDirectory: Bool = false
    ) -> FileMetadata {
        return FileMetadata(
            hash: hash,
            mtime: mtime,
            creationDate: mtime,
            vectorClock: vectorClock,
            isDirectory: isDirectory
        )
    }
}

// MARK: - DeletionRecord Helper

extension DeletionRecord {
    /// 创建测试用 DeletionRecord
    static func makeTest(
        deletedAt: Date = Date(),
        deletedBy: String = "testPeer",
        vectorClock: VectorClock
    ) -> DeletionRecord {
        return DeletionRecord(
            deletedAt: deletedAt,
            deletedBy: deletedBy,
            vectorClock: vectorClock
        )
    }
}

// MARK: - VectorClock Helper

extension VectorClock {
    /// 创建测试用 VectorClock
    static func makeTest(_ versions: [String: Int]) -> VectorClock {
        return VectorClock(versions: versions)
    }
}

// MARK: - Test Utilities

/// 等待文件系统事件稳定
func waitForFileSystem(seconds: TimeInterval = 0.1) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// 计算文件哈希
func computeFileHash(at url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
}
