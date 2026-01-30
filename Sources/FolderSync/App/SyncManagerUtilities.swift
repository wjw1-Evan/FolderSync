import Foundation
import Crypto

/// 在写入文件前准备路径，处理「同名文件/目录」冲突（如 same_name 既是文件又是目录）
/// - 若目标路径已存在且为目录，则删除（将以文件覆盖）
/// - 若父路径或祖先路径已存在且为文件，则删除（将创建为目录）
func preparePathForWritingFile(fileURL: URL, baseDir: URL, fileManager: FileManager = .default) throws {
    // 1. 目标路径已存在且为目录 → 删除
    if fileManager.fileExists(atPath: fileURL.path) {
        var isDir: ObjCBool = false
        fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir)
        if isDir.boolValue {
            try fileManager.removeItem(at: fileURL)
        }
    }
    // 2. 从直接父目录向上检查：若某祖先以文件形式存在则删除，再创建目录
    var current = fileURL.deletingLastPathComponent()
    let basePath = baseDir.path
    while current.path != basePath, !current.path.isEmpty {
        if fileManager.fileExists(atPath: current.path) {
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: current.path, isDirectory: &isDir)
            if !isDir.boolValue {
                try fileManager.removeItem(at: current)
            }
        }
        current = current.deletingLastPathComponent()
    }
}

/// 工具方法扩展
extension SyncManager {
    func isIgnored(_ path: String, folder: SyncFolder) -> Bool {
        let all = ignorePatterns + folder.excludePatterns
        for pattern in all {
            if matchesIgnore(pattern: pattern, path: path) { return true }
        }
        return false
    }

    /// Simple .gitignore-style matching: exact, suffix (*.ext), dir/ (path contains), prefix.
    func matchesIgnore(pattern: String, path: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return false }
        if p.hasSuffix("/") {
            let dir = String(p.dropLast())
            if path.contains(dir + "/") || path.hasPrefix(dir + "/") { return true }
            return path == dir
        }
        if p.hasPrefix("*.") {
            let ext = String(p.dropFirst(2))
            // Only match files with the extension, not files with that exact name
            return path.hasSuffix("." + ext)
        }
        if path == p { return true }
        if path.hasSuffix("/" + p) { return true }
        if path.contains("/" + p + "/") { return true }
        return false
    }

    /// 流式计算文件哈希（避免一次性加载大文件到内存）
    nonisolated func computeFileHash(fileURL: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        let bufferSize = 64 * 1024  // 64KB 缓冲区

        while true {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { break }
            hasher.update(data: data)
        }

        let hash = hasher.finalize()
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    func calculateFullState(for folder: SyncFolder) async -> (
        MerkleSearchTree, [String: FileMetadata], folderCount: Int, totalSize: Int64
    ) {
        return await folderStatistics.calculateFullState(for: folder)
    }
    
    /// 通过 syncID 查找文件夹（异步辅助方法）
    /// - Parameter syncID: 同步 ID
    /// - Returns: 找到的文件夹，如果不存在则返回 nil
    func findFolder(by syncID: String) async -> SyncFolder? {
        return await MainActor.run {
            return self.folders.first(where: { $0.syncID == syncID })
        }
    }

    /// 检查 syncID 是否存在于网络上的其他设备
    /// 通过尝试向已知对等点查询该 syncID 来验证
    func checkIfSyncIDExists(_ syncID: String) async -> Bool {
        // 验证 syncID 格式
        guard SyncIDManager.isValidSyncID(syncID) else {
            return false
        }

        // 首先检查本地是否已有该 syncID
        if syncIDManager.hasSyncID(syncID) {
            return true
        }

        // 检查远程设备
        let allPeers = peerManager.allPeers
        guard !allPeers.isEmpty else {
            return false
        }

        // 只检查最近收到过广播的对等点（30秒内），避免频繁连接
        for peerInfo in allPeers {
            // 检查是否最近收到过广播
            let recentlySeen = Date().timeIntervalSince(peerInfo.lastSeenTime) < 30.0
            guard recentlySeen else {
                continue
            }

            do {
                let response: SyncResponse = try await sendSyncRequest(
                    .getMST(syncID: syncID), to: peerInfo.peerID, peerID: peerInfo.peerIDString,
                    timeout: 3.0, maxRetries: 1, folder: nil)
                if case .mstRoot = response {
                    return true
                }
            } catch {
                continue
            }
        }

        return false
    }
}
