import Foundation

public enum SyncRequest: Codable {
    case getMST(syncID: String)
    case getFiles(syncID: String)
    case getFileData(syncID: String, path: String)
    case putFileData(syncID: String, path: String, data: Data, vectorClock: VectorClock?)
    case createDirectory(syncID: String, path: String, vectorClock: VectorClock?)
    case deleteFiles(syncID: String, paths: [String: VectorClock?])
    // 块级别增量同步
    case getFileChunks(syncID: String, path: String)  // 获取文件的块列表
    case getChunkData(syncID: String, chunkHash: String)  // 获取单个块数据
    case putFileChunks(
        syncID: String, path: String, chunkHashes: [String], vectorClock: VectorClock?)  // 上传文件块列表
    case putChunkData(syncID: String, chunkHash: String, data: Data)  // 上传单个块数据
}

extension SyncRequest: CustomStringConvertible {
    public var description: String {
        switch self {
        case .getMST(let id): return "getMST(\(id))"
        case .getFiles(let id): return "getFiles(\(id))"
        case .getFileData(let id, let path): return "getFileData(\(id), \(path))"
        case .putFileData(let id, let path, _, _): return "putFileData(\(id), \(path))"
        case .createDirectory(let id, let path, _): return "createDirectory(\(id), \(path))"
        case .deleteFiles(let id, let paths): return "deleteFiles(\(id), \(paths.count) files)"
        case .getFileChunks(let id, let path): return "getFileChunks(\(id), \(path))"
        case .getChunkData(let id, let hash): return "getChunkData(\(id), \(hash))"
        case .putFileChunks(let id, let path, let hashes, _):
            return "putFileChunks(\(id), \(path), \(hashes.count) chunks)"
        case .putChunkData(let id, let hash, _): return "putChunkData(\(id), \(hash))"
        }
    }
}

public struct FileMetadata: Codable {
    public let hash: String
    public let mtime: Date
    public var creationDate: Date?  // 可选，兼容旧版本
    public var vectorClock: VectorClock?
    public var isDirectory: Bool = false

    enum CodingKeys: String, CodingKey {
        case hash, mtime, creationDate, vectorClock, isDirectory
    }

    public init(
        hash: String, mtime: Date, creationDate: Date? = nil, vectorClock: VectorClock? = nil,
        isDirectory: Bool = false
    ) {
        self.hash = hash
        self.mtime = mtime
        self.creationDate = creationDate
        self.vectorClock = vectorClock
        self.isDirectory = isDirectory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hash = try container.decode(String.self, forKey: .hash)
        mtime = try container.decode(Date.self, forKey: .mtime)
        creationDate = try container.decodeIfPresent(Date.self, forKey: .creationDate)
        vectorClock = try container.decodeIfPresent(VectorClock.self, forKey: .vectorClock)
        // 使用 decodeIfPresent 并提供默认值 false，以兼容旧版本
        isDirectory = try container.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
    }
}

public enum SyncResponse: Codable {
    case mstRoot(syncID: String, rootHash: String)
    case files(syncID: String, entries: [String: FileMetadata], deletedPaths: [String] = [])  // path: metadata, deletedPaths: 删除记录（tombstones）
    // 新版本：统一状态表示（逐步迁移）
    case filesV2(syncID: String, states: [String: FileState])  // path: FileState（统一的状态表示）
    case fileData(syncID: String, path: String, data: Data)
    case putAck(syncID: String, path: String)
    case deleteAck(syncID: String)
    case error(String)
    // 块级别增量同步响应
    case fileChunks(syncID: String, path: String, chunkHashes: [String])  // 文件的块列表
    case chunkData(syncID: String, chunkHash: String, data: Data)  // 单个块数据
    case chunkAck(syncID: String, chunkHash: String)  // 块上传确认
    case fileChunksAck(syncID: String, path: String)  // 文件块列表上传确认
}
