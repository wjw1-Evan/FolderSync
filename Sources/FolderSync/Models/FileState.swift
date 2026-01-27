import Foundation

/// 文件状态枚举
/// 统一表示文件的存在/删除状态
public enum FileState: Codable {
    /// 文件存在
    case exists(FileMetadata)
    /// 文件已删除（tombstone）
    case deleted(DeletionRecord)
    
    /// 获取文件元数据（如果存在）
    var metadata: FileMetadata? {
        if case .exists(let meta) = self {
            return meta
        }
        return nil
    }
    
    /// 获取删除记录（如果已删除）
    var deletionRecord: DeletionRecord? {
        if case .deleted(let record) = self {
            return record
        }
        return nil
    }
    
    /// 检查文件是否已删除
    var isDeleted: Bool {
        if case .deleted = self {
            return true
        }
        return false
    }
    
    /// 获取 Vector Clock
    var vectorClock: VectorClock? {
        switch self {
        case .exists(let meta):
            return meta.vectorClock
        case .deleted(let record):
            return record.vectorClock
        }
    }
}

/// 删除记录
/// 记录文件的删除信息，用于防止已删除的文件被重新同步
public struct DeletionRecord: Codable {
    /// 删除时间
    let deletedAt: Date
    /// 删除者（PeerID）
    let deletedBy: String
    /// 删除时的 Vector Clock
    let vectorClock: VectorClock
    
    public init(deletedAt: Date = Date(), deletedBy: String, vectorClock: VectorClock) {
        self.deletedAt = deletedAt
        self.deletedBy = deletedBy
        self.vectorClock = vectorClock
    }
}

/// 文件元数据扩展
/// 确保 FileMetadata 包含 Vector Clock
extension FileMetadata {
    /// 创建文件状态（存在）
    public func toFileState() -> FileState {
        return .exists(self)
    }
}
