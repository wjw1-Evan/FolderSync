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
    
    private let blocks = Table("blocks")
    private let b_id = Expression<String>("id") // Content hash
    private let b_size = Expression<Int64>("size")
    private let b_path = Expression<String>("path") // Local storage path for the block
    
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
        })
        
        try db.run(blocks.create(ifNotExists: true) { t in
            t.column(b_id, primaryKey: true)
            t.column(b_size)
            t.column(b_path)
        })
    }
    
    public func saveFolder(_ folder: SyncFolder) throws {
        let insert = folders.insert(or: .replace,
            f_id <- folder.id.uuidString,
            f_syncID <- folder.syncID,
            f_localPath <- folder.localPath.path,
            f_mode <- folder.mode.rawValue,
            f_status <- folder.status.rawValue
        )
        try db.run(insert)
    }
    
    public func getAllFolders() throws -> [SyncFolder] {
        var result: [SyncFolder] = []
        for row in try db.prepare(folders) {
            result.append(SyncFolder(
                id: UUID(uuidString: row[f_id])!,
                syncID: row[f_syncID],
                localPath: URL(fileURLWithPath: row[f_localPath]),
                mode: SyncMode(rawValue: row[f_mode])!,
                status: SyncStatus(rawValue: row[f_status])!
            ))
        }
        return result
    }
}
