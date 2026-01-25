import Foundation

/// 地址转换工具 - 将 Multiaddr 格式转换为简单的 IP:Port 格式
public struct AddressConverter {
    /// 从 Multiaddr 字符串提取 IP 和端口
    /// 例如：/ip4/192.168.1.100/tcp/51027 -> 192.168.1.100:51027
    public static func extractIPPort(from multiaddr: String) -> (ip: String, port: UInt16)? {
        // 解析格式：/ip4/IP/tcp/PORT
        let components = multiaddr.split(separator: "/")
        var ip: String?
        var port: UInt16?
        
        var i = 0
        while i < components.count {
            if components[i] == "ip4" && i + 1 < components.count {
                ip = String(components[i + 1])
                i += 2
            } else if components[i] == "tcp" && i + 1 < components.count {
                if let portNum = UInt16(components[i + 1]) {
                    port = portNum
                }
                i += 2
            } else {
                i += 1
            }
        }
        
        guard let ipValue = ip, let portValue = port else {
            return nil
        }
        
        return (ip: ipValue, port: portValue)
    }
    
    /// 将 IP 和端口转换为地址字符串
    public static func makeAddress(ip: String, port: UInt16) -> String {
        return "\(ip):\(port)"
    }
    
    /// 从地址字符串数组提取第一个有效地址
    public static func extractFirstAddress(from addresses: [String]) -> String? {
        for addr in addresses {
            if let (ip, port) = extractIPPort(from: addr) {
                return makeAddress(ip: ip, port: port)
            }
        }
        return nil
    }
}
