import Foundation

public enum SyncMode: String, Codable {
    case twoWay
    case uploadOnly
    case downloadOnly
}

public enum SyncStatus: String, Codable {
    case synced
    case syncing
    case error
    case paused
}

public struct SyncFolder: Identifiable, Codable {
    public let id: UUID
    public let syncID: String // Global unique identifier for the sync group
    public var localPath: URL
    public var mode: SyncMode
    public var status: SyncStatus
    public var syncProgress: Double = 0.0
    public var lastSyncMessage: String?
    public var lastSyncedAt: Date?
    public var peerCount: Int = 0
    public var fileCount: Int? = 0
    public var folderCount: Int? = 0
    public var excludePatterns: [String]
    
    public init(id: UUID = UUID(), syncID: String, localPath: URL, mode: SyncMode = .twoWay, status: SyncStatus = .synced, excludePatterns: [String] = []) {
        self.id = id
        self.syncID = syncID
        self.localPath = localPath
        self.mode = mode
        self.status = status
        self.excludePatterns = excludePatterns
    }
    
    // 自定义编码/解码以正确处理 URL
    enum CodingKeys: String, CodingKey {
        case id, syncID, localPath, mode, status, syncProgress
        case lastSyncMessage, lastSyncedAt, peerCount, fileCount, folderCount, excludePatterns
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        syncID = try container.decode(String.self, forKey: .syncID)
        
        // URL 需要特殊处理：先解码为字符串，再转换为 URL
        let pathString = try container.decode(String.self, forKey: .localPath)
        if let url = URL(string: pathString) {
            localPath = url
        } else {
            // 如果 URL(string:) 失败，尝试使用 fileURL(withPath:)
            // 移除 file:// 前缀（如果存在）
            let filePath = pathString.hasPrefix("file://") ? String(pathString.dropFirst(7)) : pathString
            localPath = URL(fileURLWithPath: filePath)
        }
        
        mode = try container.decode(SyncMode.self, forKey: .mode)
        status = try container.decode(SyncStatus.self, forKey: .status)
        syncProgress = try container.decodeIfPresent(Double.self, forKey: .syncProgress) ?? 0.0
        lastSyncMessage = try container.decodeIfPresent(String.self, forKey: .lastSyncMessage)
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        peerCount = try container.decodeIfPresent(Int.self, forKey: .peerCount) ?? 0
        fileCount = try container.decodeIfPresent(Int.self, forKey: .fileCount)
        folderCount = try container.decodeIfPresent(Int.self, forKey: .folderCount)
        excludePatterns = try container.decodeIfPresent([String].self, forKey: .excludePatterns) ?? []
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(syncID, forKey: .syncID)
        
        // URL 编码为字符串（使用绝对路径）
        try container.encode(localPath.absoluteString, forKey: .localPath)
        
        try container.encode(mode, forKey: .mode)
        try container.encode(status, forKey: .status)
        try container.encode(syncProgress, forKey: .syncProgress)
        try container.encodeIfPresent(lastSyncMessage, forKey: .lastSyncMessage)
        try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encode(peerCount, forKey: .peerCount)
        try container.encodeIfPresent(fileCount, forKey: .fileCount)
        try container.encodeIfPresent(folderCount, forKey: .folderCount)
        try container.encode(excludePatterns, forKey: .excludePatterns)
    }
}
