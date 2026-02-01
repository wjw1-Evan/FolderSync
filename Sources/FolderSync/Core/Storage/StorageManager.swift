import Foundation

extension Notification.Name {
    static let syncLogAdded = Notification.Name("syncLogAdded")
    static let localChangeAdded = Notification.Name("localChangeAdded")
    static let localChangeHistoryRefresh = Notification.Name("localChangeHistoryRefresh")
}

public class StorageManager {
    public static let shared = try! StorageManager()

    private let appDir: URL
    private let fileManager = FileManager.default

    // 文件路径
    private var foldersFile: URL { appDir.appendingPathComponent("folders.json") }
    private var conflictsFile: URL { appDir.appendingPathComponent("conflicts.json") }
    private var syncLogsFile: URL { appDir.appendingPathComponent("sync_logs.json") }
    private var localChangesFile: URL { appDir.appendingPathComponent("local_changes.json") }
    private var deletedRecordsFile: URL { appDir.appendingPathComponent("deleted_records.json") }
    private var snapshotsDir: URL { appDir.appendingPathComponent("snapshots", isDirectory: true) }
    private var vectorClocksDir: URL {
        appDir.appendingPathComponent("vector_clocks", isDirectory: true)
    }
    private var blocksDir: URL { appDir.appendingPathComponent("blocks", isDirectory: true) }  // 块存储目录

    // 内存缓存
    private var foldersCache: [SyncFolder]?
    private var conflictsCache: [ConflictFile]?
    private var syncLogsCache: [SyncLog]?
    private var localChangesCache: [LocalChange]?
    private var deletedRecordsCache: [String: Set<String>]?
    private let cacheQueue = DispatchQueue(label: "com.foldersync.storage.cache")
    private var nextLogSequence: Int64 = 1
    private var nextLocalChangeSequence: Int64 = 1

    init() throws {
        appDir = AppPaths.appDirectory

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

        // 创建快照存储目录
        if !fileManager.fileExists(atPath: snapshotsDir.path) {
            try fileManager.createDirectory(
                at: snapshotsDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
        }

        // 初始化缓存
        _ = try? loadFolders()
        _ = try? loadConflicts()
        _ = try? loadSyncLogs()
        _ = try? loadLocalChanges()
        _ = try? loadDeletedRecords()

        // 初始化同步日志的序列号，确保并发写入有全局递增顺序
        let logs = (try? loadSyncLogs(forceReload: true)) ?? []
        let maxSeq = logs.compactMap { $0.sequence }.max() ?? 0
        self.nextLogSequence = maxSeq + 1

        // 初始化本地变更日志序列
        let localChanges = (try? loadLocalChanges(forceReload: true)) ?? []
        let maxLocalSeq = localChanges.compactMap { $0.sequence }.max() ?? 0
        self.nextLocalChangeSequence = maxLocalSeq + 1
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
                AppLogger.syncPrint("[StorageManager] ❌ 无法读取文件夹配置文件: \(foldersFile.path)")
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
                AppLogger.syncPrint("[StorageManager] ❌ 解析文件夹配置失败: \(error)")
                AppLogger.syncPrint("[StorageManager] 错误详情: \(error.localizedDescription)")

                // 备份损坏的文件，以便后续恢复
                let backupFile = foldersFile.appendingPathExtension(
                    "corrupted.\(Int(Date().timeIntervalSince1970)).backup")
                do {
                    try data.write(to: backupFile, options: [.atomic])
                    AppLogger.syncPrint(
                        "[StorageManager] 💾 已备份损坏的配置文件到: \(backupFile.lastPathComponent)")
                    AppLogger.syncPrint("[StorageManager] ⚠️ 警告: 文件夹配置解析失败，已备份损坏的文件")
                    AppLogger.syncPrint("[StorageManager]   如果这是重要数据，请尝试手动修复或从备份恢复")
                } catch {
                    AppLogger.syncPrint(
                        "[StorageManager] ⚠️ 无法备份损坏的配置文件: \(error.localizedDescription)")
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
                    AppLogger.syncPrint(
                        "[StorageManager] ⚠️ 无法备份旧配置文件: \(error.localizedDescription)")
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
            AppLogger.syncPrint("[StorageManager] ❌ 保存文件夹配置失败: \(error)")
            AppLogger.syncPrint("[StorageManager] 错误详情: \(error.localizedDescription)")
            AppLogger.syncPrint("[StorageManager] 文件路径: \(foldersFile.path)")

            // 如果写入失败，尝试从备份恢复
            let backupFile = foldersFile.appendingPathExtension("backup")
            if fileManager.fileExists(atPath: backupFile.path) {
                do {
                    let backupData = try Data(contentsOf: backupFile)
                    try? backupData.write(to: foldersFile, options: [.atomic])
                    // 恢复成功，不输出日志
                } catch {
                    AppLogger.syncPrint("[StorageManager] ❌ 从备份恢复失败: \(error.localizedDescription)")
                }
            }

            throw error
        }
    }

    // MARK: - 向量时钟管理

    public func getVectorClock(folderID: UUID, syncID: String, path: String) -> VectorClock? {
        let fileURL = vectorClockFile(folderID: folderID, syncID: syncID, path: path)
        guard fileManager.fileExists(atPath: fileURL.path),
            let data = try? Data(contentsOf: fileURL),
            let vc = try? JSONDecoder().decode(VectorClock.self, from: data)
        else {
            return nil
        }
        return vc
    }

    public func setVectorClock(folderID: UUID, syncID: String, path: String, _ vc: VectorClock)
        throws
    {
        let fileURL = vectorClockFile(folderID: folderID, syncID: syncID, path: path)
        let dir = fileURL.deletingLastPathComponent()

        // 确保目录存在
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let data = try JSONEncoder().encode(vc)
        try data.write(to: fileURL, options: [.atomic])
    }

    /// 批量保存 Vector Clock (并行写入)
    public func setVectorClocks(folderID: UUID, syncID: String, updates: [String: VectorClock])
        async throws
    {
        if updates.isEmpty { return }

        // 1. 确保目录存在（只检查一次）
        // 这里假设同一个 syncID 下的所有 VC 都在同一个目录（或者少量几个子目录）
        // vectorClockFile 实现显示它是基于 folderID/syncID/path 结构的
        // 目前 vectorClockFile 的实现是将 path 扁平化为文件名，所以都在 syncID 目录下
        let samplePath = updates.keys.first ?? "sample"
        let sampleURL = vectorClockFile(folderID: folderID, syncID: syncID, path: samplePath)
        let dir = sampleURL.deletingLastPathComponent()

        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // 2. 并行写入
        // 使用 actor 来安全收集错误
        actor ErrorCollector {
            var errors: [Error] = []
            func add(_ error: Error) { errors.append(error) }
            func first() -> Error? { return errors.first }
        }
        let collector = ErrorCollector()

        let encoder = JSONEncoder()

        // 使用 withThrowingTaskGroup 因为我们想等待所有完成，但不一定要抛出第一个错误，
        // 我们想尽可能保存更多，然后报告错误
        await withTaskGroup(of: Void.self) { group in
            for (path, vc) in updates {
                group.addTask {
                    do {
                        let fileURL = self.vectorClockFile(
                            folderID: folderID, syncID: syncID, path: path)
                        let data = try encoder.encode(vc)
                        try data.write(to: fileURL, options: [.atomic])
                    } catch {
                        await collector.add(error)
                        AppLogger.syncPrint(
                            "[StorageManager] ⚠️ 批量保存 Vector Clock 失败: \(path), 错误: \(error)")
                    }
                }
            }
        }

        // 如果有错误，抛出第一个
        if let firstError = await collector.first() {
            throw firstError
        }
    }

    public func deleteVectorClock(folderID: UUID, syncID: String, path: String) throws {
        let fileURL = vectorClockFile(folderID: folderID, syncID: syncID, path: path)
        try? fileManager.removeItem(at: fileURL)
    }

    private func vectorClockFile(folderID: UUID, syncID: String, path: String) -> URL {
        // 将路径中的 / 替换为 _ 作为文件名
        let safePath = path.replacingOccurrences(of: "/", with: "_").replacingOccurrences(
            of: "\\", with: "_")
        // 以 folderID 作为命名空间，避免同一进程/同一用户下多个“设备”实例共享同一份 VC 数据
        let folderDir = vectorClocksDir.appendingPathComponent(
            folderID.uuidString, isDirectory: true)
        let syncDir = folderDir.appendingPathComponent(syncID, isDirectory: true)
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
        var newLog = log
        var caughtError: Error?

        cacheQueue.sync {
            do {
                var logs = try loadSyncLogsLocked()

                // 分配全局递增序列，解决并发写入顺序问题
                if newLog.sequence == nil {
                    newLog.sequence = nextLogSequence
                    nextLogSequence += 1
                } else if let seq = newLog.sequence, seq >= nextLogSequence {
                    nextLogSequence = seq + 1
                }

                if let index = logs.firstIndex(where: { $0.id == newLog.id }) {
                    logs[index] = newLog
                } else {
                    logs.append(newLog)
                }

                // 排序并限制日志数量（保留最新的 1000 条），按 sequence 降序优先，其次 startedAt
                logs = sortLogsForDisplay(logs)
                if logs.count > 1000 {
                    logs = Array(logs.prefix(1000))
                }

                try saveSyncLogsLocked(logs)
            } catch {
                caughtError = error
            }
        }

        if let err = caughtError { throw err }

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

        // 按 sequence 优先排序（降序），解决并发写入的时间一致性问题
        logs = sortLogsForDisplay(logs)

        // 限制数量
        return Array(logs.prefix(limit))
    }

    private func loadSyncLogs(forceReload: Bool = false) throws -> [SyncLog] {
        return cacheQueue.sync {
            if !forceReload, let cached = syncLogsCache {
                return cached
            }
            return (try? loadSyncLogsLocked()) ?? []
        }
    }

    // 仅在 cacheQueue 内调用，避免重复加锁
    private func loadSyncLogsLocked() throws -> [SyncLog] {
        if let cached = syncLogsCache {
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

    private func saveSyncLogs(_ logs: [SyncLog]) throws {
        let data = try JSONEncoder().encode(logs)
        try data.write(to: syncLogsFile, options: [.atomic])

        cacheQueue.sync {
            syncLogsCache = logs
        }
    }

    // 仅在 cacheQueue 内调用，避免重复加锁
    private func saveSyncLogsLocked(_ logs: [SyncLog]) throws {
        let data = try JSONEncoder().encode(logs)
        try data.write(to: syncLogsFile, options: [.atomic])
        syncLogsCache = logs
    }

    // 统一排序：sequence 优先（越大越新），否则按 startedAt
    private func sortLogsForDisplay(_ logs: [SyncLog]) -> [SyncLog] {
        return logs.sorted { lhs, rhs in
            switch (lhs.sequence, rhs.sequence) {
            case (let ls?, let rs?):
                if ls == rs { return lhs.startedAt > rhs.startedAt }
                return ls > rs
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.startedAt > rhs.startedAt
            }
        }
    }

    // MARK: - 本地变更历史

    public func addLocalChanges(_ newChanges: [LocalChange]) throws {
        if newChanges.isEmpty { return }

        var caughtError: Error?

        cacheQueue.sync {
            do {
                var changes = try loadLocalChangesLocked()

                for var newChange in newChanges {
                    // 分配全局递增序列
                    if newChange.sequence == nil {
                        newChange.sequence = nextLocalChangeSequence
                        nextLocalChangeSequence += 1
                    } else if let seq = newChange.sequence, seq >= nextLocalChangeSequence {
                        nextLocalChangeSequence = seq + 1
                    }

                    // 检查是否已有相同 ID 的记录
                    if let index = changes.firstIndex(where: { $0.id == newChange.id }) {
                        changes[index] = newChange
                    } else {
                        changes.append(newChange)
                    }
                }

                // 按 sequence 降序排序，限制数量（保留最新的 2000 条）
                changes = sortLocalChangesForDisplay(changes)
                if changes.count > 2000 {
                    changes = Array(changes.prefix(2000))
                }

                try saveLocalChangesLocked(changes)
            } catch {
                caughtError = error
            }
        }

        if let err = caughtError { throw err }

        NotificationCenter.default.post(name: .localChangeAdded, object: nil)
    }

    public func addLocalChange(_ change: LocalChange) throws {
        try addLocalChanges([change])
    }

    public func getLocalChanges(folderID: UUID? = nil, limit: Int = 200, forceReload: Bool = false)
        throws -> [LocalChange]
    {
        var changes = try loadLocalChanges(forceReload: forceReload)
        if let fid = folderID {
            changes = changes.filter { $0.folderID == fid }
        }

        changes = sortLocalChangesForDisplay(changes)
        return Array(changes.prefix(limit))
    }

    private func loadLocalChanges(forceReload: Bool = false) throws -> [LocalChange] {
        return cacheQueue.sync {
            if !forceReload, let cached = localChangesCache {
                return cached
            }
            return (try? loadLocalChangesLocked()) ?? []
        }
    }

    // 仅在 cacheQueue 内调用，避免重复加锁
    private func loadLocalChangesLocked() throws -> [LocalChange] {
        if let cached = localChangesCache {
            return cached
        }

        guard fileManager.fileExists(atPath: localChangesFile.path),
            let data = try? Data(contentsOf: localChangesFile),
            let changes = try? JSONDecoder().decode([LocalChange].self, from: data)
        else {
            let empty: [LocalChange] = []
            localChangesCache = empty
            return empty
        }

        localChangesCache = changes
        return changes
    }

    private func saveLocalChanges(_ changes: [LocalChange]) throws {
        let data = try JSONEncoder().encode(changes)
        try data.write(to: localChangesFile, options: [.atomic])

        cacheQueue.sync {
            localChangesCache = changes
        }
    }

    // 仅在 cacheQueue 内调用，避免重复加锁
    private func saveLocalChangesLocked(_ changes: [LocalChange]) throws {
        let data = try JSONEncoder().encode(changes)
        try data.write(to: localChangesFile, options: [.atomic])
        localChangesCache = changes
    }

    // 统一排序：sequence 优先（越大越新），否则按 timestamp
    private func sortLocalChangesForDisplay(_ changes: [LocalChange]) -> [LocalChange] {
        return changes.sorted { lhs, rhs in
            switch (lhs.sequence, rhs.sequence) {
            case (let ls?, let rs?):
                if ls == rs { return lhs.timestamp > rhs.timestamp }
                return ls > rs
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.timestamp > rhs.timestamp
            }
        }
    }

    // MARK: - 文件夹快照管理（原子记录）

    /// 原子性地保存文件夹快照
    /// 使用临时文件 + 原子移动确保原子性
    public func saveSnapshot(_ snapshot: FolderSnapshot) throws {
        let snapshotFile = snapshotsDir.appendingPathComponent("\(snapshot.syncID).json")
        let tempFile = snapshotFile.appendingPathExtension("tmp")

        // 先写入临时文件
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: tempFile, options: [.atomic])

        // 如果目标文件已存在，先删除（moveItem 不会自动替换）
        if fileManager.fileExists(atPath: snapshotFile.path) {
            try fileManager.removeItem(at: snapshotFile)
        }

        // 原子性地移动到目标文件
        try fileManager.moveItem(at: tempFile, to: snapshotFile)
    }

    /// 加载指定 syncID 的最新快照
    public func loadSnapshot(syncID: String) throws -> FolderSnapshot? {
        let snapshotFile = snapshotsDir.appendingPathComponent("\(syncID).json")

        guard fileManager.fileExists(atPath: snapshotFile.path) else {
            return nil
        }

        let data = try Data(contentsOf: snapshotFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FolderSnapshot.self, from: data)
    }

    /// 加载所有快照
    public func loadAllSnapshots() throws -> [FolderSnapshot] {
        guard fileManager.fileExists(atPath: snapshotsDir.path) else {
            return []
        }

        let files = try fileManager.contentsOfDirectory(
            at: snapshotsDir, includingPropertiesForKeys: nil)
        let jsonFiles = files.filter { $0.pathExtension == "json" }

        var snapshots: [FolderSnapshot] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in jsonFiles {
            do {
                let data = try Data(contentsOf: file)
                let snapshot = try decoder.decode(FolderSnapshot.self, from: data)
                snapshots.append(snapshot)
            } catch {
                AppLogger.syncPrint("[StorageManager] ⚠️ 无法加载快照 \(file.lastPathComponent): \(error)")
                // 继续处理其他文件
            }
        }

        return snapshots
    }

    /// 删除指定 syncID 的快照
    public func deleteSnapshot(syncID: String) throws {
        let snapshotFile = snapshotsDir.appendingPathComponent("\(syncID).json")
        if fileManager.fileExists(atPath: snapshotFile.path) {
            try fileManager.removeItem(at: snapshotFile)
        }
    }

    /// 比较两个快照，返回变更列表
    public func compareSnapshots(_ old: FolderSnapshot?, _ new: FolderSnapshot) -> (
        created: [String],
        modified: [String],
        deleted: [String],
        renamed: [(old: String, new: String)]
    ) {
        guard let old = old else {
            // 如果没有旧快照，所有文件都是新建的
            return (created: Array(new.files.keys), modified: [], deleted: [], renamed: [])
        }

        var created: [String] = []
        var modified: [String] = []
        var deleted: [String] = []
        var renamed: [(old: String, new: String)] = []

        let oldPaths = Set(old.files.keys)
        let newPaths = Set(new.files.keys)

        // 检测删除和可能的重命名
        for oldPath in oldPaths {
            if !newPaths.contains(oldPath) {
                let oldFile = old.files[oldPath]!
                // 尝试通过哈希值匹配重命名
                var foundRename = false
                for (newPath, newFile) in new.files {
                    if !oldPaths.contains(newPath) && oldFile.hash == newFile.hash {
                        renamed.append((old: oldPath, new: newPath))
                        foundRename = true
                        break
                    }
                }
                if !foundRename {
                    deleted.append(oldPath)
                }
            }
        }

        // 检测新建和修改
        for newPath in newPaths {
            if !oldPaths.contains(newPath) {
                // 检查是否已经在重命名列表中
                if !renamed.contains(where: { $0.new == newPath }) {
                    created.append(newPath)
                }
            } else {
                // 检查是否修改（通过哈希值比较）
                let oldFile = old.files[newPath]!
                let newFile = new.files[newPath]!
                if oldFile.hash != newFile.hash {
                    modified.append(newPath)
                }
            }
        }

        return (created: created, modified: modified, deleted: deleted, renamed: renamed)
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
