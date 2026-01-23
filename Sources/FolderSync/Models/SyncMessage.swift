import Foundation

public enum SyncRequest: Codable {
    case getMST(syncID: String)
    case getFiles(syncID: String)
    case getFileData(syncID: String, path: String)
}

public struct FileMetadata: Codable {
    public let hash: String
    public let mtime: Date
}

public enum SyncResponse: Codable {
    case mstRoot(syncID: String, rootHash: String)
    case files(syncID: String, entries: [String: FileMetadata]) // path: metadata
    case fileData(syncID: String, path: String, data: Data)
    case error(String)
}
