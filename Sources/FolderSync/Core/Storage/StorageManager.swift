import Foundation

extension Notification.Name {
    static let syncLogAdded = Notification.Name("syncLogAdded")
}

public class StorageManager {
    public static let shared = try! StorageManager()

    private let appDir: URL
    private let fileManager = FileManager.default

    // 文件路径
    private var foldersFile: URL { appDir.appendingPathComponent("folders.json") }
    private var conflictsFile: URL { appDir.appendingPathComponent("conflicts.json") }
    private var syncLogsFile: URL { appDir.appendingPathComponent("sync_logs.json") }
    private var deletedRecordsFile: URL { appDir.appendingPathComponent("deleted_records.json") }
    private var vectorClocksDir: URL {
        appDir.appendingPathComponent("vector_clocks", isDirectory: true)
    }
    private var blocksDir: URL { appDir.appendingPathComponent("blocks", isDirectory: true) }  // 块存储目录

    // 内存缓存
    private var foldersCache: [SyncFolder]?
    private var conflictsCache: [ConflictFile]?
    private var syncLogsCache: [SyncLog]?
    private var deletedRecordsCache: [String: Set<String>]?
    private let cacheQueue = DispatchQueue(label: "com.foldersync.storage.cache")

    init() throws {
        let path = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true
        ).first!
        appDir = URL(fileURLWithPath: path).appendingPathComponent("FolderSync")

        // 确保目录存在并设置正确的权限
        if !fileManager.fileExists(atPath: appDir.path) {
            try fileManager.createDirectory(
                at: appDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
        }

        // 创建向量时钟目录
        if !fileManager.fileExists(atPath: vectorClocksDir.path) {
            try fileManager.createDirectory(
                at: vectorClocksDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
        }

        // 创建块存储目录
        if !fileManager.fileExists(atPath: blocksDir.path) {
            try fileManager.createDirectory(
                at: blocksDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
        }

        // 初始化缓存
        _ = try? loadFolders()
        _ = try? loadConflicts()
        _ = try? loadSyncLogs()
        _ = try? loadDeletedRecords()
    }

    // MARK: - 文件夹管理

    public func saveFolder(_ folder: SyncFolder) throws {
        var folders = try loadFolders()

        // 查找并更新或添加
        if let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index] = folder
        } else {
            folders.append(folder)
        }

        try saveFolders(folders)
    }

    public func getAllFolders() throws -> [SyncFolder] {
        return try loadFolders()
    }

    public func deleteFolder(_ folderID: UUID) throws {
        var folders = try loadFolders()
        folders.removeAll { $0.id == folderID }
        try saveFolders(folders)
    }

    private func loadFolders() throws -> [SyncFolder] {
        return cacheQueue.sync {
            if let cached = foldersCache {
                return cached
            }

            guard fileManager.fileExists(atPath: foldersFile.path) else {
                // 首次运行，不输出日志
                let empty: [SyncFolder] = []
                foldersCache = empty
                return empty
            }

            guard let data = try? Data(contentsOf: foldersFile) else {
                print("[StorageManager] ❌ 无法读取文件夹配置文件: \(foldersFile.path)")
                let empty: [SyncFolder] = []
                foldersCache = empty
                return empty
            }

            do {
                let folders = try JSONDecoder().decode([SyncFolder].self, from: data)
                foldersCache = folders
                // 成功加载，不输出日志
                return folders
            } catch {
                print("[StorageManager] ❌ 解析文件夹配置失败: \(error)")
                print("[StorageManager] 错误详情: \(error.localizedDescription)")

                // 备份损坏的文件，以便后续恢复
                let backupFile = foldersFile.appendingPathExtension(
                    "corrupted.\(Int(Date().timeIntervalSince1970)).backup")
                do {
                    try data.write(to: backupFile, options: [.atomic])
                    print("[StorageManager] 💾 已备份损坏的配置文件到: \(backupFile.lastPathComponent)")
                    print("[StorageManager] ⚠️ 警告: 文件夹配置解析失败，已备份损坏的文件")
                    print("[StorageManager]   如果这是重要数据，请尝试手动修复或从备份恢复")
                } catch {
                    print("[StorageManager] ⚠️ 无法备份损坏的配置文件: \(error.localizedDescription)")
                }

                // 如果解析失败，返回空数组而不是抛出错误，避免应用启动失败
                // 但用户需要知道数据可能丢失
                let empty: [SyncFolder] = []
                foldersCache = empty
                return empty
            }
        }
    }

    private func saveFolders(_ folders: [SyncFolder]) throws {
        do {
            let data = try JSONEncoder().encode(folders)

            // 在写入新数据前，如果旧文件存在，先备份（以防写入失败导致数据丢失）
            let backupFile = foldersFile.appendingPathExtension("backup")
            if fileManager.fileExists(atPath: foldersFile.path) {
                do {
                    let oldData = try Data(contentsOf: foldersFile)
                    try? oldData.write(to: backupFile, options: [.atomic])
                } catch {
                    // 备份失败不影响主流程，只记录警告
                    print("[StorageManager] ⚠️ 无法备份旧配置文件: \(error.localizedDescription)")
                }
            }

            // 使用原子写入，确保数据完整性
            try data.write(to: foldersFile, options: [.atomic])

            // 写入成功后，更新缓存
            cacheQueue.sync {
                foldersCache = folders
            }

            // 写入成功后，删除备份文件（如果存在）
            try? fileManager.removeItem(at: backupFile)

            // 成功保存，不输出日志
        } catch {
            print("[StorageManager] ❌ 保存文件夹配置失败: \(error)")
            print("[StorageManager] 错误详情: \(error.localizedDescription)")
            print("[StorageManager] 文件路径: \(foldersFile.path)")

            // 如果写入失败，尝试从备份恢复
            let backupFile = foldersFile.appendingPathExtension("backup")
            if fileManager.fileExists(atPath: backupFile.path) {
                do {
                    let backupData = try Data(contentsOf: backupFile)
                    try? backupData.write(to: foldersFile, options: [.atomic])
                    // 恢复成功，不输出日志
                } catch {
                    print("[StorageManager] ❌ 从备份恢复失败: \(error.localizedDescription)")
                }
            }

            throw error
        }
    }

    // MARK: - 向量时钟管理

    public func getVectorClock(syncID: String, path: String) -> VectorClock? {
        let fileURL = vectorClockFile(syncID: syncID, path: path)
        guard fileManager.fileExists(atPath: fileURL.path),
            let data = try? Data(contentsOf: fileURL),
            let vc = try? JSONDecoder().decode(VectorClock.self, from: data)
        else {
            return nil
        }
        return vc
    }

    public func setVectorClock(syncID: String, path: String, _ vc: VectorClock) throws {
        let fileURL = vectorClockFile(syncID: syncID, path: path)
        let dir = fileURL.deletingLastPathComponent()

        // 确保目录存在
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let data = try JSONEncoder().encode(vc)
        try data.write(to: fileURL, options: [.atomic])
    }

    public func deleteVectorClock(syncID: String, path: String) throws {
        let fileURL = vectorClockFile(syncID: syncID, path: path)
        try? fileManager.removeItem(at: fileURL)
    }

    private func vectorClockFile(syncID: String, path: String) -> URL {
        // 将路径中的 / 替换为 _ 作为文件名
        let safePath = path.replacingOccurrences(of: "/", with: "_").replacingOccurrences(
            of: "\\", with: "_")
        let syncDir = vectorClocksDir.appendingPathComponent(syncID, isDirectory: true)
        return syncDir.appendingPathComponent("\(safePath).json")
    }

    // MARK: - 冲突文件管理

    public func addConflict(_ c: ConflictFile) throws {
        var conflicts = try loadConflicts()

        // 检查是否已存在
        if conflicts.contains(where: { $0.id == c.id }) {
            // 更新现有冲突
            if let index = conflicts.firstIndex(where: { $0.id == c.id }) {
                conflicts[index] = c
            }
        } else {
            conflicts.append(c)
        }

        try saveConflicts(conflicts)
    }

    public func getAllConflicts(syncID: String? = nil, unresolvedOnly: Bool = true) throws
        -> [ConflictFile]
    {
        var conflicts = try loadConflicts()

        if let sid = syncID {
            conflicts = conflicts.filter { $0.syncID == sid }
        }

        if unresolvedOnly {
            conflicts = conflicts.filter { !$0.resolved }
        }

        return conflicts
    }

    public func resolveConflict(id: UUID) throws {
        var conflicts = try loadConflicts()
        if let index = conflicts.firstIndex(where: { $0.id == id }) {
            conflicts[index].resolved = true
            try saveConflicts(conflicts)
        }
    }

    public func deleteConflict(id: UUID) throws {
        var conflicts = try loadConflicts()
        conflicts.removeAll { $0.id == id }
        try saveConflicts(conflicts)
    }

    private func loadConflicts() throws -> [ConflictFile] {
        return cacheQueue.sync {
            if let cached = conflictsCache {
                return cached
            }

            guard fileManager.fileExists(atPath: conflictsFile.path),
                let data = try? Data(contentsOf: conflictsFile),
                let conflicts = try? JSONDecoder().decode([ConflictFile].self, from: data)
            else {
                let empty: [ConflictFile] = []
                conflictsCache = empty
                return empty
            }

            conflictsCache = conflicts
            return conflicts
        }
    }

    private func saveConflicts(_ conflicts: [ConflictFile]) throws {
        let data = try JSONEncoder().encode(conflicts)
        try data.write(to: conflictsFile, options: [.atomic])

        cacheQueue.sync {
            conflictsCache = conflicts
        }
    }

    // MARK: - 同步日志管理

    public func addSyncLog(_ log: SyncLog) throws {
        var logs = try loadSyncLogs()

        // 检查是否已存在（相同 ID）
        if let index = logs.firstIndex(where: { $0.id == log.id }) {
            logs[index] = log
        } else {
            logs.append(log)
        }

        // 限制日志数量（保留最新的 1000 条）
        if logs.count > 1000 {
            logs.sort { $0.startedAt > $1.startedAt }
            logs = Array(logs.prefix(1000))
        }

        try saveSyncLogs(logs)

        // 发送通知，通知视图刷新
        NotificationCenter.default.post(name: .syncLogAdded, object: nil)
    }

    public func getSyncLogs(syncID: String? = nil, limit: Int = 100, forceReload: Bool = false)
        throws -> [SyncLog]
    {
        // 根据参数决定是否强制重新加载
        var logs = try loadSyncLogs(forceReload: forceReload)

        if let sid = syncID {
            logs = logs.filter { $0.syncID == sid }
        }

        // 按时间倒序排序
        logs.sort { $0.startedAt > $1.startedAt }

        // 限制数量
        return Array(logs.prefix(limit))
    }

    private func loadSyncLogs(forceReload: Bool = false) throws -> [SyncLog] {
        return cacheQueue.sync {
            if !forceReload, let cached = syncLogsCache {
                return cached
            }

            guard fileManager.fileExists(atPath: syncLogsFile.path),
                let data = try? Data(contentsOf: syncLogsFile),
                let logs = try? JSONDecoder().decode([SyncLog].self, from: data)
            else {
                let empty: [SyncLog] = []
                syncLogsCache = empty
                return empty
            }

            syncLogsCache = logs
            return logs
        }
    }

    private func saveSyncLogs(_ logs: [SyncLog]) throws {
        let data = try JSONEncoder().encode(logs)
        try data.write(to: syncLogsFile, options: [.atomic])

        cacheQueue.sync {
            syncLogsCache = logs
        }
    }

    // MARK: - 删除记录（Tombstones）

    /// 获取所有已记录的删除（syncID -> Set<path>）
    public func getDeletedRecords() throws -> [String: Set<String>] {
        return try loadDeletedRecords()
    }

    /// 覆盖保存删除记录（syncID -> Set<path>）
    public func saveDeletedRecords(_ records: [String: Set<String>]) throws {
        let encodable = records.mapValues { Array($0) }
        let data = try JSONEncoder().encode(encodable)
        try data.write(to: deletedRecordsFile, options: [.atomic])

        cacheQueue.sync {
            deletedRecordsCache = records
        }
    }

    private func loadDeletedRecords() throws -> [String: Set<String>] {
        return cacheQueue.sync {
            if let cached = deletedRecordsCache {
                return cached
            }

            guard fileManager.fileExists(atPath: deletedRecordsFile.path),
                let data = try? Data(contentsOf: deletedRecordsFile),
                let raw = try? JSONDecoder().decode([String: [String]].self, from: data)
            else {
                let empty: [String: Set<String>] = [:]
                deletedRecordsCache = empty
                return empty
            }

            let converted: [String: Set<String>] = raw.mapValues { Set($0) }
            deletedRecordsCache = converted
            return converted
        }
    }

    // MARK: - 块存储管理

    /// 获取块的存储路径（使用哈希的前2个字符作为子目录，避免单个目录文件过多）
    private func blockPath(for hash: String) -> URL {
        let prefix = String(hash.prefix(2))
        let subDir = blocksDir.appendingPathComponent(prefix, isDirectory: true)
        // 确保子目录存在
        try? fileManager.createDirectory(at: subDir, withIntermediateDirectories: true)
        return subDir.appendingPathComponent(hash)
    }

    /// 保存块数据
    public func saveBlock(hash: String, data: Data) throws {
        let blockURL = blockPath(for: hash)
        try data.write(to: blockURL, options: [.atomic])
    }

    /// 获取块数据
    public func getBlock(hash: String) throws -> Data? {
        let blockURL = blockPath(for: hash)
        guard fileManager.fileExists(atPath: blockURL.path) else {
            return nil
        }
        return try Data(contentsOf: blockURL)
    }

    /// 检查块是否存在
    public func hasBlock(hash: String) -> Bool {
        let blockURL = blockPath(for: hash)
        return fileManager.fileExists(atPath: blockURL.path)
    }

    /// 删除块（用于清理不再使用的块）
    public func deleteBlock(hash: String) throws {
        let blockURL = blockPath(for: hash)
        if fileManager.fileExists(atPath: blockURL.path) {
            try fileManager.removeItem(at: blockURL)
        }
    }

    /// 批量检查块是否存在
    public func hasBlocks(hashes: [String]) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for hash in hashes {
            result[hash] = hasBlock(hash: hash)
        }
        return result
    }
}
