import Foundation

/// 冲突文件过滤器
/// 用于识别和排除冲突文件，防止冲突文件被重复同步
class ConflictFileFilter {
    
    /// 检查文件路径是否是冲突文件
    /// - Parameter path: 文件路径（相对路径或文件名）
    /// - Returns: 如果是冲突文件返回 true
    static func isConflictFile(_ path: String) -> Bool {
        // 冲突文件的命名格式：文件名.conflict.{peerID}.{timestamp}.扩展名
        // 或者：文件名.conflict.{peerID1}.{timestamp1}.conflict.{peerID2}.{timestamp2}.扩展名（嵌套冲突）
        let fileName = (path as NSString).lastPathComponent
        return fileName.contains(".conflict.")
    }
    
    /// 从文件元数据字典中过滤掉冲突文件
    /// - Parameter metadata: 文件元数据字典
    /// - Returns: 过滤后的文件元数据字典（不包含冲突文件）
    static func filterConflictFiles(_ metadata: [String: FileMetadata]) -> [String: FileMetadata] {
        return metadata.filter { !isConflictFile($0.key) }
    }
    
    /// 从文件路径集合中过滤掉冲突文件
    /// - Parameter paths: 文件路径集合
    /// - Returns: 过滤后的文件路径集合（不包含冲突文件）
    static func filterConflictFiles(_ paths: Set<String>) -> Set<String> {
        return paths.filter { !isConflictFile($0) }
    }
    
    /// 从文件路径数组中过滤掉冲突文件
    /// - Parameter paths: 文件路径数组
    /// - Returns: 过滤后的文件路径数组（不包含冲突文件）
    static func filterConflictFiles(_ paths: [String]) -> [String] {
        return paths.filter { !isConflictFile($0) }
    }
}
