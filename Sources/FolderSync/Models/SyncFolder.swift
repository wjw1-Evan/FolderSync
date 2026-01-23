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
    
    public init(id: UUID = UUID(), syncID: String, localPath: URL, mode: SyncMode = .twoWay, status: SyncStatus = .synced) {
        self.id = id
        self.syncID = syncID
        self.localPath = localPath
        self.mode = mode
        self.status = status
    }
}
