import Foundation

public struct SyncLog: Identifiable, Codable {
    public let id: UUID
    public let syncID: String
    public let folderID: UUID
    public let peerID: String?
    public let direction: Direction
    public var sequence: Int64?
    public let bytesTransferred: Int64
    public let filesCount: Int
    public let startedAt: Date
    public let completedAt: Date?
    public let errorMessage: String?
    public let syncedFiles: [SyncedFileInfo]?  // 同步的文件列表

    public struct SyncedFileInfo: Codable {
        public let path: String  // 相对路径
        public let fileName: String  // 文件名
        public let folderName: String?  // 文件夹名称（如果有）
        public let size: Int64  // 文件大小
        public let operation: FileOperation  // 操作类型

        public enum FileOperation: String, Codable {
            case upload
            case download
            case delete
            case conflict
        }

        public init(
            path: String, fileName: String, folderName: String?, size: Int64,
            operation: FileOperation
        ) {
            self.path = path
            self.fileName = fileName
            self.folderName = folderName
            self.size = size
            self.operation = operation
        }
    }

    public enum Direction: String, Codable {
        case upload
        case download
        case bidirectional
    }

    public init(
        id: UUID = UUID(), syncID: String, folderID: UUID, peerID: String?, direction: Direction,
        bytesTransferred: Int64, filesCount: Int, startedAt: Date, completedAt: Date? = nil,
        errorMessage: String? = nil, syncedFiles: [SyncedFileInfo]? = nil, sequence: Int64? = nil
    ) {
        self.id = id
        self.syncID = syncID
        self.folderID = folderID
        self.peerID = peerID
        self.direction = direction
        self.sequence = sequence
        self.bytesTransferred = bytesTransferred
        self.filesCount = filesCount
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
        self.syncedFiles = syncedFiles
    }
}
