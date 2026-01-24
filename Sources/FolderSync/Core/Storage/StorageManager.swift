import Foundation
import SQLite

public class StorageManager {
    public static let shared = try! StorageManager()
    
    private let db: Connection
    
    // Tables
    private let folders = Table("folders")
    private let f_id = Expression<String>("id")
    private let f_syncID = Expression<String>("sync_id")
    private let f_localPath = Expression<String>("local_path")
    private let f_mode = Expression<String>("mode")
    private let f_status = Expression<String>("status")
    private let f_excludePatterns = Expression<String>("exclude_patterns")
    
    private let blocks = Table("blocks")
    private let b_id = Expression<String>("id") // Content hash
    private let b_size = Expression<Int64>("size")
    private let b_path = Expression<String>("path") // Local storage path for the block
    
    private let fileVersions = Table("file_versions")
    private let fv_syncID = Expression<String>("sync_id")
    private let fv_path = Expression<String>("path")
    private let fv_vectorClock = Expression<String>("vector_clock_json")
    
    private let conflictFiles = Table("conflict_files")
    
    private let syncLogs = Table("sync_logs")
    private let sl_id = Expression<String>("id")
    private let sl_syncID = Expression<String>("sync_id")
    private let sl_folderID = Expression<String>("folder_id")
    private let sl_peerID = Expression<String?>("peer_id")
    private let sl_direction = Expression<String>("direction")
    private let sl_bytesTransferred = Expression<Int64>("bytes_transferred")
    private let sl_filesCount = Expression<Int>("files_count")
    private let sl_startedAt = Expression<Date>("started_at")
    private let sl_completedAt = Expression<Date?>("completed_at")
    private let sl_errorMessage = Expression<String?>("error_message")
    private let cf_id = Expression<String>("id")
    private let cf_syncID = Expression<String>("sync_id")
    private let cf_relativePath = Expression<String>("relative_path")
    private let cf_conflictPath = Expression<String>("conflict_path")
    private let cf_remotePeerID = Expression<String>("remote_peer_id")
    private let cf_createdAt = Expression<Date>("created_at")
    private let cf_resolved = Expression<Bool>("resolved")
    
    init() throws {
        let path = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first!
        let appDir = URL(fileURLWithPath: path).appendingPathComponent("FolderSync")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        
        let dbPath = appDir.appendingPathComponent("db.sqlite3").path
        db = try Connection(dbPath)
        
        try setupSchema()
    }
    
    private func setupSchema() throws {
        try db.run(folders.create(ifNotExists: true) { t in
            t.column(f_id, primaryKey: true)
            t.column(f_syncID)
            t.column(f_localPath)
            t.column(f_mode)
            t.column(f_status)
            t.column(f_excludePatterns, defaultValue: "[]")
        })
        try? db.execute("ALTER TABLE folders ADD COLUMN exclude_patterns TEXT DEFAULT '[]'")
        
        try db.run(blocks.create(ifNotExists: true) { t in
            t.column(b_id, primaryKey: true)
            t.column(b_size)
            t.column(b_path)
        })
        
        try db.run(fileVersions.create(ifNotExists: true) { t in
            t.column(fv_syncID)
            t.column(fv_path)
            t.column(fv_vectorClock)
            t.primaryKey(fv_syncID, fv_path)
        })
        
        try db.run(conflictFiles.create(ifNotExists: true) { t in
            t.column(cf_id, primaryKey: true)
            t.column(cf_syncID)
            t.column(cf_relativePath)
            t.column(cf_conflictPath)
            t.column(cf_remotePeerID)
            t.column(cf_createdAt)
            t.column(cf_resolved)
        })
        
        try db.run(syncLogs.create(ifNotExists: true) { t in
            t.column(sl_id, primaryKey: true)
            t.column(sl_syncID)
            t.column(sl_folderID)
            t.column(sl_peerID)
            t.column(sl_direction)
            t.column(sl_bytesTransferred)
            t.column(sl_filesCount)
            t.column(sl_startedAt)
            t.column(sl_completedAt)
            t.column(sl_errorMessage)
        })
    }
    
    public func getVectorClock(syncID: String, path: String) -> VectorClock? {
        let query = fileVersions.filter(fv_syncID == syncID && fv_path == path)
        guard let row = try? db.pluck(query),
              let data = row[fv_vectorClock].data(using: .utf8),
              let vc = try? JSONDecoder().decode(VectorClock.self, from: data) else { return nil }
        return vc
    }
    
    public func setVectorClock(syncID: String, path: String, _ vc: VectorClock) throws {
        let json = (try? JSONEncoder().encode(vc)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let insert = fileVersions.insert(or: .replace, fv_syncID <- syncID, fv_path <- path, fv_vectorClock <- json)
        try db.run(insert)
    }
    
    public func deleteVectorClock(syncID: String, path: String) throws {
        try db.run(fileVersions.filter(fv_syncID == syncID && fv_path == path).delete())
    }
    
    public func addConflict(_ c: ConflictFile) throws {
        let insert = conflictFiles.insert(
            cf_id <- c.id.uuidString,
            cf_syncID <- c.syncID,
            cf_relativePath <- c.relativePath,
            cf_conflictPath <- c.conflictPath,
            cf_remotePeerID <- c.remotePeerID,
            cf_createdAt <- c.createdAt,
            cf_resolved <- c.resolved
        )
        try db.run(insert)
    }
    
    public func getAllConflicts(syncID: String? = nil, unresolvedOnly: Bool = true) throws -> [ConflictFile] {
        var query = conflictFiles
        if let sid = syncID {
            query = query.filter(cf_syncID == sid)
        }
        if unresolvedOnly {
            query = query.filter(cf_resolved == false)
        }
        var result: [ConflictFile] = []
        for row in try db.prepare(query) {
            result.append(ConflictFile(
                id: UUID(uuidString: row[cf_id])!,
                syncID: row[cf_syncID],
                relativePath: row[cf_relativePath],
                conflictPath: row[cf_conflictPath],
                remotePeerID: row[cf_remotePeerID],
                createdAt: row[cf_createdAt],
                resolved: row[cf_resolved]
            ))
        }
        return result
    }
    
    public func resolveConflict(id: UUID) throws {
        try db.run(conflictFiles.filter(cf_id == id.uuidString).update(cf_resolved <- true))
    }
    
    public func deleteConflict(id: UUID) throws {
        try db.run(conflictFiles.filter(cf_id == id.uuidString).delete())
    }
    
    public func addSyncLog(_ log: SyncLog) throws {
        let insert = syncLogs.insert(
            sl_id <- log.id.uuidString,
            sl_syncID <- log.syncID,
            sl_folderID <- log.folderID.uuidString,
            sl_peerID <- log.peerID,
            sl_direction <- log.direction.rawValue,
            sl_bytesTransferred <- log.bytesTransferred,
            sl_filesCount <- log.filesCount,
            sl_startedAt <- log.startedAt,
            sl_completedAt <- log.completedAt,
            sl_errorMessage <- log.errorMessage
        )
        try db.run(insert)
    }
    
    public func getSyncLogs(syncID: String? = nil, limit: Int = 100) throws -> [SyncLog] {
        func toLog(_ row: Row) -> SyncLog {
            let dir = SyncLog.Direction(rawValue: row[sl_direction]) ?? .bidirectional
            return SyncLog(
                id: UUID(uuidString: row[sl_id])!,
                syncID: row[sl_syncID],
                folderID: UUID(uuidString: row[sl_folderID])!,
                peerID: row[sl_peerID],
                direction: dir,
                bytesTransferred: row[sl_bytesTransferred],
                filesCount: row[sl_filesCount],
                startedAt: row[sl_startedAt],
                completedAt: row[sl_completedAt],
                errorMessage: row[sl_errorMessage]
            )
        }
        if let sid = syncID {
            return try Array(db.prepare(syncLogs.filter(sl_syncID == sid).order(sl_startedAt.desc).limit(limit))).map(toLog)
        }
        return try Array(db.prepare(syncLogs.order(sl_startedAt.desc).limit(limit))).map(toLog)
    }
    
    public func saveFolder(_ folder: SyncFolder) throws {
        let patternsJson = (try? JSONEncoder().encode(folder.excludePatterns)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let insert = folders.insert(or: .replace,
            f_id <- folder.id.uuidString,
            f_syncID <- folder.syncID,
            f_localPath <- folder.localPath.path,
            f_mode <- folder.mode.rawValue,
            f_status <- folder.status.rawValue,
            f_excludePatterns <- patternsJson
        )
        try db.run(insert)
    }
    
    public func getAllFolders() throws -> [SyncFolder] {
        var result: [SyncFolder] = []
        for row in try db.prepare(folders) {
            let patternsJson = (try? row.get(f_excludePatterns)) ?? "[]"
            let patterns = (try? JSONDecoder().decode([String].self, from: Data(patternsJson.utf8))) ?? []
            result.append(SyncFolder(
                id: UUID(uuidString: row[f_id])!,
                syncID: row[f_syncID],
                localPath: URL(fileURLWithPath: row[f_localPath]),
                mode: SyncMode(rawValue: row[f_mode])!,
                status: SyncStatus(rawValue: row[f_status])!,
                excludePatterns: patterns
            ))
        }
        return result
    }
    public func deleteFolder(_ folderID: UUID) throws {
        let query = folders.filter(f_id == folderID.uuidString)
        try db.run(query.delete())
    }
}
