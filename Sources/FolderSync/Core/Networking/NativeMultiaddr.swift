import Foundation

/// 原生 Multiaddr 实现 - 替代 libp2p 的 Multiaddr
public struct Multiaddr: Hashable, Codable, CustomStringConvertible {
    private let addressString: String
    
    /// 从字符串创建 Multiaddr
    public init(_ string: String) throws {
        // 验证格式：应该是 /ip4/xxx/tcp/xxx 或类似格式
        guard string.hasPrefix("/") else {
            throw MultiaddrError.invalidFormat
        }
        self.addressString = string
    }
    
    /// 从字符串创建 Multiaddr（不抛出异常）
    public init?(string: String) {
        guard string.hasPrefix("/") else {
            return nil
        }
        self.addressString = string
    }
    
    public var description: String {
        return addressString
    }
}

public enum MultiaddrError: Error {
    case invalidFormat
}
