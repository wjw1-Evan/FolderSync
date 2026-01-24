import Foundation

public struct SyncLog: Identifiable, Codable {
    public let id: UUID
    public let syncID: String
    public let folderID: UUID
    public let peerID: String?
    public let direction: Direction
    public let bytesTransferred: Int64
    public let filesCount: Int
    public let startedAt: Date
    public let completedAt: Date?
    public let errorMessage: String?
    
    public enum Direction: String, Codable {
        case upload
        case download
        case bidirectional
    }
    
    public init(id: UUID = UUID(), syncID: String, folderID: UUID, peerID: String?, direction: Direction, bytesTransferred: Int64, filesCount: Int, startedAt: Date, completedAt: Date? = nil, errorMessage: String? = nil) {
        self.id = id
        self.syncID = syncID
        self.folderID = folderID
        self.peerID = peerID
        self.direction = direction
        self.bytesTransferred = bytesTransferred
        self.filesCount = filesCount
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
    }
}
