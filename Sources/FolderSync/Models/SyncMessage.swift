import Foundation

public enum SyncRequest: Codable {
    case getMST(syncID: String)
    case getFiles(syncID: String)
    case getFileData(syncID: String, path: String)
    case putFileData(syncID: String, path: String, data: Data, vectorClock: VectorClock?)
    case deleteFiles(syncID: String, paths: [String])
}

public struct FileMetadata: Codable {
    public let hash: String
    public let mtime: Date
    public var vectorClock: VectorClock?
    
    public init(hash: String, mtime: Date, vectorClock: VectorClock? = nil) {
        self.hash = hash
        self.mtime = mtime
        self.vectorClock = vectorClock
    }
}

public enum SyncResponse: Codable {
    case mstRoot(syncID: String, rootHash: String)
    case files(syncID: String, entries: [String: FileMetadata]) // path: metadata
    case fileData(syncID: String, path: String, data: Data)
    case putAck(syncID: String, path: String)
    case deleteAck(syncID: String)
    case error(String)
}
