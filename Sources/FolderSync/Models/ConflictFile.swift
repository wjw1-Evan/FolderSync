import Foundation

public struct ConflictFile: Identifiable, Codable, Hashable {
    public let id: UUID
    public let syncID: String
    public let relativePath: String
    public let conflictPath: String
    public let remotePeerID: String
    public let createdAt: Date
    public var resolved: Bool
    
    public init(id: UUID = UUID(), syncID: String, relativePath: String, conflictPath: String, remotePeerID: String, createdAt: Date = Date(), resolved: Bool = false) {
        self.id = id
        self.syncID = syncID
        self.relativePath = relativePath
        self.conflictPath = conflictPath
        self.remotePeerID = remotePeerID
        self.createdAt = createdAt
        self.resolved = resolved
    }
}
