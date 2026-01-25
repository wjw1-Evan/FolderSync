import Foundation

/// 地址转换工具 - 将 Multiaddr 格式转换为简单的 IP:Port 格式
public struct AddressConverter {
    /// 从 Multiaddr 字符串提取 IP 和端口
    /// 例如：/ip4/192.168.1.100/tcp/51027 -> 192.168.1.100:51027
    /// 注意：端口为0的地址会被拒绝（0表示自动分配，不能用于连接）
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
                let portStr = String(components[i + 1])
                if let portNum = UInt16(portStr) {
                    port = portNum
                } else {
                    print("[AddressConverter] ⚠️ 无法解析端口: '\(portStr)' (来源: \(multiaddr))")
                }
                i += 2
            } else {
                i += 1
            }
        }
        
        guard let ipValue = ip, let portValue = port, portValue > 0 else {
            // 端口为0或无效，拒绝此地址
            if let ipValue = ip {
                print("[AddressConverter] ⚠️ 地址无效: IP=\(ipValue), 端口=\(port?.description ?? "nil"), 原始=\(multiaddr)")
            } else {
                print("[AddressConverter] ⚠️ 地址无效: 无法提取IP或端口, 原始=\(multiaddr)")
            }
            return nil
        }
        
        // 验证IP地址格式
        if ipValue.isEmpty || ipValue == "0.0.0.0" {
            print("[AddressConverter] ⚠️ IP地址无效: '\(ipValue)' (来源: \(multiaddr))")
            return nil
        }
        
        // 验证端口范围（1-65535）
        if portValue == 0 || portValue > 65535 {
            print("[AddressConverter] ⚠️ 端口超出范围: \(portValue) (来源: \(multiaddr))")
            return nil
        }
        
        print("[AddressConverter] ✅ 成功提取: IP=\(ipValue), 端口=\(portValue) (来源: \(multiaddr))")
        return (ip: ipValue, port: portValue)
    }
    
    /// 将 IP 和端口转换为地址字符串
    public static func makeAddress(ip: String, port: UInt16) -> String {
        return "\(ip):\(port)"
    }
    
    /// 从地址字符串数组提取第一个有效地址
    /// 注意：会跳过端口为0的地址（0表示自动分配，不能用于连接）
    public static func extractFirstAddress(from addresses: [String]) -> String? {
        print("[AddressConverter] 🔍 开始提取地址，总数: \(addresses.count)")
        for (index, addr) in addresses.enumerated() {
            print("[AddressConverter] 🔍 检查地址\(index+1)/\(addresses.count): \(addr)")
            if let (ip, port) = extractIPPort(from: addr), port > 0 {
                let result = makeAddress(ip: ip, port: port)
                print("[AddressConverter] ✅ 提取到有效地址: \(result) (来源: \(addr))")
                return result
            }
        }
        print("[AddressConverter] ❌ 没有找到有效地址（共检查 \(addresses.count) 个地址）")
        return nil
    }
}
