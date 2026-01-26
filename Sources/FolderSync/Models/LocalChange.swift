import Foundation

public struct LocalChange: Identifiable, Codable, Equatable {
    public enum ChangeType: String, Codable {
        case created
        case modified
        case deleted
        case renamed
    }

    public var id: UUID = UUID()
    public var folderID: UUID
    public var path: String
    public var changeType: ChangeType
    public var size: Int64?
    public var timestamp: Date = Date()
    public var sequence: Int64?
}
