import Foundation

/// 简单的密码管理器，使用文件存储而不是 Keychain
/// 避免每次启动都需要用户输入密码
public enum KeychainManager {
    private static let passwordFileName = "peerid_password.txt"
    
    /// 获取密码文件路径
    private static func passwordFilePath() -> URL? {
        let folderSyncDir = AppPaths.appDirectory
        return folderSyncDir.appendingPathComponent(passwordFileName)
    }
    
    /// 从文件加载密码
    public static func loadPassword() -> String? {
        guard let filePath = passwordFilePath(),
              FileManager.default.fileExists(atPath: filePath.path),
              let data = try? Data(contentsOf: filePath),
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// 保存密码到文件
    public static func savePassword(_ password: String) -> Bool {
        guard let filePath = passwordFilePath(),
              let data = password.data(using: .utf8) else {
            return false
        }
        
        do {
            try data.write(to: filePath, options: [.atomic, .completeFileProtection])
            // 设置文件权限，仅所有者可读写
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath.path)
            return true
        } catch {
            AppLogger.syncPrint("[KeychainManager] 保存密码失败: \(error)")
            return false
        }
    }
    
    /// 删除密码文件
    public static func deletePassword() {
        guard let filePath = passwordFilePath(),
              FileManager.default.fileExists(atPath: filePath.path) else {
            return
        }
        try? FileManager.default.removeItem(at: filePath)
    }
    
    /// 返回现有密码或生成、存储并返回新密码
    public static func loadOrCreatePassword() -> String {
        if let existing = loadPassword(), !existing.isEmpty {
            return existing
        }
        // 生成新密码
        let new = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32).description
        _ = savePassword(new)
        return new
    }
}
