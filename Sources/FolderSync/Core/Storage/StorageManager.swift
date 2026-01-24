import Foundation

public class StorageManager {
    public static let shared = try! StorageManager()
    
    private let appDir: URL
    private let fileManager = FileManager.default
    
    // 文件路径
    private var foldersFile: URL { appDir.appendingPathComponent("folders.json") }
    private var conflictsFile: URL { appDir.appendingPathComponent("conflicts.json") }
    private var syncLogsFile: URL { appDir.appendingPathComponent("sync_logs.json") }
    private var vectorClocksDir: URL { appDir.appendingPathComponent("vector_clocks", isDirectory: true) }
    
    // 内存缓存
    private var foldersCache: [SyncFolder]?
    private var conflictsCache: [ConflictFile]?
    private var syncLogsCache: [SyncLog]?
    private let cacheQueue = DispatchQueue(label: "com.foldersync.storage.cache")
    
    init() throws {
        let path = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first!
        appDir = URL(fileURLWithPath: path).appendingPathComponent("FolderSync")
        
        // 确保目录存在并设置正确的权限
        if !fileManager.fileExists(atPath: appDir.path) {
            try fileManager.createDirectory(at: appDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        
        // 创建向量时钟目录
        if !fileManager.fileExists(atPath: vectorClocksDir.path) {
            try fileManager.createDirectory(at: vectorClocksDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        
        // 初始化缓存
        _ = try? loadFolders()
        _ = try? loadConflicts()
        _ = try? loadSyncLogs()
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
        return try cacheQueue.sync {
            if let cached = foldersCache {
                return cached
            }
            
            guard fileManager.fileExists(atPath: foldersFile.path) else {
                print("[StorageManager] ℹ️ 文件夹配置文件不存在: \(foldersFile.path)")
                print("[StorageManager] ℹ️ 这是首次运行，将创建新的配置文件")
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
                print("[StorageManager] ✅ 成功加载 \(folders.count) 个文件夹配置")
                return folders
            } catch {
                print("[StorageManager] ❌ 解析文件夹配置失败: \(error)")
                print("[StorageManager] 错误详情: \(error.localizedDescription)")
                // 如果解析失败，返回空数组而不是抛出错误，避免应用启动失败
                let empty: [SyncFolder] = []
                foldersCache = empty
                return empty
            }
        }
    }
    
    private func saveFolders(_ folders: [SyncFolder]) throws {
        do {
            let data = try JSONEncoder().encode(folders)
            try data.write(to: foldersFile, options: [.atomic])
            
            cacheQueue.sync {
                foldersCache = folders
            }
            
            print("[StorageManager] ✅ 成功保存 \(folders.count) 个文件夹配置到: \(foldersFile.path)")
        } catch {
            print("[StorageManager] ❌ 保存文件夹配置失败: \(error)")
            print("[StorageManager] 错误详情: \(error.localizedDescription)")
            print("[StorageManager] 文件路径: \(foldersFile.path)")
            throw error
        }
    }
    
    // MARK: - 向量时钟管理
    
    public func getVectorClock(syncID: String, path: String) -> VectorClock? {
        let fileURL = vectorClockFile(syncID: syncID, path: path)
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let vc = try? JSONDecoder().decode(VectorClock.self, from: data) else {
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
        let safePath = path.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
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
    
    public func getAllConflicts(syncID: String? = nil, unresolvedOnly: Bool = true) throws -> [ConflictFile] {
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
        return try cacheQueue.sync {
            if let cached = conflictsCache {
                return cached
            }
            
            guard fileManager.fileExists(atPath: conflictsFile.path),
                  let data = try? Data(contentsOf: conflictsFile),
                  let conflicts = try? JSONDecoder().decode([ConflictFile].self, from: data) else {
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
    }
    
    public func getSyncLogs(syncID: String? = nil, limit: Int = 100) throws -> [SyncLog] {
        var logs = try loadSyncLogs()
        
        if let sid = syncID {
            logs = logs.filter { $0.syncID == sid }
        }
        
        // 按时间倒序排序
        logs.sort { $0.startedAt > $1.startedAt }
        
        // 限制数量
        return Array(logs.prefix(limit))
    }
    
    private func loadSyncLogs() throws -> [SyncLog] {
        return try cacheQueue.sync {
            if let cached = syncLogsCache {
                return cached
            }
            
            guard fileManager.fileExists(atPath: syncLogsFile.path),
                  let data = try? Data(contentsOf: syncLogsFile),
                  let logs = try? JSONDecoder().decode([SyncLog].self, from: data) else {
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
}
