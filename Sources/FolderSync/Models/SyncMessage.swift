import Foundation

public enum SyncRequest: Codable {
    case getMST(syncID: String)
    case getFiles(syncID: String)
    case getFileData(syncID: String, path: String)
    case putFileData(syncID: String, path: String, data: Data, vectorClock: VectorClock?)
    case deleteFiles(syncID: String, paths: [String])
    // 块级别增量同步
    case getFileChunks(syncID: String, path: String) // 获取文件的块列表
    case getChunkData(syncID: String, chunkHash: String) // 获取单个块数据
    case putFileChunks(syncID: String, path: String, chunkHashes: [String], vectorClock: VectorClock?) // 上传文件块列表
    case putChunkData(syncID: String, chunkHash: String, data: Data) // 上传单个块数据
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
    case files(syncID: String, entries: [String: FileMetadata], deletedPaths: [String] = []) // path: metadata, deletedPaths: 删除记录（tombstones）
    // 新版本：统一状态表示（逐步迁移）
    case filesV2(syncID: String, states: [String: FileState]) // path: FileState（统一的状态表示）
    case fileData(syncID: String, path: String, data: Data)
    case putAck(syncID: String, path: String)
    case deleteAck(syncID: String)
    case error(String)
    // 块级别增量同步响应
    case fileChunks(syncID: String, path: String, chunkHashes: [String]) // 文件的块列表
    case chunkData(syncID: String, chunkHash: String, data: Data) // 单个块数据
    case chunkAck(syncID: String, chunkHash: String) // 块上传确认
    case fileChunksAck(syncID: String, path: String) // 文件块列表上传确认
}
