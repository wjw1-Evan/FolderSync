import Foundation
import Crypto

/// 原生 PeerID 实现 - 替代 libp2p 的 PeerID
public struct PeerID: Hashable, Codable {
    public let b58String: String
    public let rawBytes: Data
    
    /// 从 base58 字符串创建 PeerID
    public init?(cid: String) {
        self.b58String = cid
        // 简化实现：直接存储字符串，不进行 base58 解码
        // 如果需要，可以使用 Crypto 库进行解码
        self.rawBytes = Data()
    }
    
    /// 生成新的 PeerID（使用随机密钥）
    public static func generate() -> PeerID {
        // 生成 32 字节的随机数据
        var randomBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard status == errSecSuccess else {
            // 如果随机数生成失败，使用 UUID
            let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            return PeerID(b58String: uuid, rawBytes: Data())
        }
        
        // 使用 base58 编码（简化实现，使用十六进制）
        let hexString = randomBytes.map { String(format: "%02x", $0) }.joined()
        return PeerID(b58String: hexString, rawBytes: Data(randomBytes))
    }
    
    /// 从持久化存储加载 PeerID
    public static func load(from fileURL: URL, password: String) -> PeerID? {
        // 简化实现：从文件读取字符串
        guard let data = try? Data(contentsOf: fileURL),
              let peerIDString = String(data: data, encoding: .utf8) else {
            return nil
        }
        return PeerID(b58String: peerIDString, rawBytes: Data())
    }
    
    /// 保存 PeerID 到文件
    public func save(to fileURL: URL, password: String) throws {
        // 简化实现：直接保存字符串
        try b58String.data(using: .utf8)?.write(to: fileURL)
    }
    
    private init(b58String: String, rawBytes: Data) {
        self.b58String = b58String
        self.rawBytes = rawBytes
    }
}
