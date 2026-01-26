import Foundation

/// 文件夹快照
/// 原子记录所有文件的状态，用于多端同步时比较变更
public struct FolderSnapshot: Codable, Identifiable {
    public let id: UUID
    public let syncID: String
    public let folderID: UUID
    public let timestamp: Date
    public let files: [String: FileSnapshot]  // 相对路径 -> 文件快照
    
    /// 文件快照信息
    public struct FileSnapshot: Codable {
        public let hash: String  // 文件哈希值
        public let mtime: Date   // 修改时间
        public let size: Int64   // 文件大小
        public let vectorClock: VectorClock?  // 向量时钟（用于冲突检测）
        
        public init(hash: String, mtime: Date, size: Int64, vectorClock: VectorClock? = nil) {
            self.hash = hash
            self.mtime = mtime
            self.size = size
            self.vectorClock = vectorClock
        }
    }
    
    public init(
        id: UUID = UUID(),
        syncID: String,
        folderID: UUID,
        timestamp: Date = Date(),
        files: [String: FileSnapshot]
    ) {
        self.id = id
        self.syncID = syncID
        self.folderID = folderID
        self.timestamp = timestamp
        self.files = files
    }
    
    /// 转换为 FileMetadata 字典（用于兼容现有代码）
    public func toFileMetadata() -> [String: FileMetadata] {
        var result: [String: FileMetadata] = [:]
        for (path, snapshot) in files {
            result[path] = FileMetadata(
                hash: snapshot.hash,
                mtime: snapshot.mtime,
                vectorClock: snapshot.vectorClock
            )
        }
        return result
    }
    
    /// 从 FileMetadata 字典创建快照
    public static func fromFileMetadata(
        syncID: String,
        folderID: UUID,
        metadata: [String: FileMetadata],
        fileSizes: [String: Int64] = [:]
    ) -> FolderSnapshot {
        var files: [String: FileSnapshot] = [:]
        for (path, meta) in metadata {
            let size = fileSizes[path] ?? 0
            files[path] = FileSnapshot(
                hash: meta.hash,
                mtime: meta.mtime,
                size: size,
                vectorClock: meta.vectorClock
            )
        }
        return FolderSnapshot(
            syncID: syncID,
            folderID: folderID,
            files: files
        )
    }
}
