import Foundation

/// 文件状态存储
/// 统一管理文件的存在/删除状态
class FileStateStore {
    /// 文件状态映射：path -> FileState
    private var states: [String: FileState] = [:]
    
    /// 同步队列（确保线程安全）
    private let queue = DispatchQueue(label: "com.foldersync.filestatestore", attributes: .concurrent)
    
    /// 获取文件状态
    func getState(for path: String) -> FileState? {
        return queue.sync {
            return states[path]
        }
    }
    
    /// 设置文件存在
    func setExists(path: String, metadata: FileMetadata) {
        queue.async(flags: .barrier) {
            self.states[path] = .exists(metadata)
        }
    }
    
    /// 设置文件删除
    func setDeleted(path: String, record: DeletionRecord) {
        queue.async(flags: .barrier) {
            self.states[path] = .deleted(record)
        }
    }
    
    /// 移除文件状态
    func removeState(path: String) {
        queue.async(flags: .barrier) {
            self.states.removeValue(forKey: path)
        }
    }
    
    /// 检查文件是否已删除
    func isDeleted(path: String) -> Bool {
        return queue.sync {
            if case .deleted = states[path] {
                return true
            }
            return false
        }
    }
    
    /// 获取所有文件状态
    func getAllStates() -> [String: FileState] {
        return queue.sync {
            return states
        }
    }
    
    /// 批量设置状态
    func setStates(_ newStates: [String: FileState]) {
        queue.async(flags: .barrier) {
            self.states.merge(newStates) { (_, new) in new }
        }
    }
    
    /// 获取所有已删除的文件路径
    func getDeletedPaths() -> Set<String> {
        return queue.sync {
            var deletedPaths: Set<String> = []
            for (path, state) in states {
                if case .deleted = state {
                    deletedPaths.insert(path)
                }
            }
            return deletedPaths
        }
    }
    
    /// 清理过期的删除记录
    /// - Parameters:
    ///   - expirationTime: 过期时间（秒），默认30天
    ///   - confirmedByAllPeers: 是否所有对等点都已确认删除
    func cleanupExpiredDeletions(expirationTime: TimeInterval = 30 * 24 * 60 * 60, confirmedByAllPeers: @escaping (String) -> Bool) {
        queue.async(flags: .barrier) {
            let now = Date()
            var pathsToRemove: [String] = []
            
            for (path, state) in self.states {
                if case .deleted(let record) = state {
                    // 检查是否过期
                    if now.timeIntervalSince(record.deletedAt) > expirationTime {
                        // 检查是否所有对等点都已确认
                        if confirmedByAllPeers(path) {
                            pathsToRemove.append(path)
                        }
                    }
                }
            }
            
            // 移除过期的删除记录
            for path in pathsToRemove {
                self.states.removeValue(forKey: path)
            }
        }
    }
}
