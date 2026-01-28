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
        
        return (ip: ipValue, port: portValue)
    }
    
    /// 将 IP 和端口转换为地址字符串
    public static func makeAddress(ip: String, port: UInt16) -> String {
        return "\(ip):\(port)"
    }
    
    /// 获取 IP 地址的优先级（数字越小优先级越高）
    /// - 优先级 1: 局域网地址 (192.168.x.x, 10.x.x.x, 172.16-31.x.x)
    /// - 优先级 2: 链路本地地址 (169.254.x.x) - 通常不可靠
    /// - 优先级 3: 其他地址
    private static func addressPriority(ip: String) -> Int {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return 3 }
        
        // 局域网地址优先级最高
        if parts[0] == 192 && parts[1] == 168 {
            return 1  // 192.168.x.x
        }
        if parts[0] == 10 {
            return 1  // 10.x.x.x
        }
        if parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31 {
            return 1  // 172.16-31.x.x
        }
        
        // 链路本地地址优先级最低（通常不可靠）
        if parts[0] == 169 && parts[1] == 254 {
            return 2  // 169.254.x.x
        }
        
        // 其他地址
        return 3
    }
    
    /// 从地址字符串数组提取第一个有效地址（按优先级排序）
    /// 优先选择局域网地址，避免选择链路本地地址
    /// 注意：会跳过端口为0的地址（0表示自动分配，不能用于连接）
    public static func extractFirstAddress(from addresses: [String]) -> String? {
        // 提取所有有效地址并计算优先级
        var validAddresses: [(address: String, ip: String, port: UInt16, priority: Int)] = []
        
        for addr in addresses {
            if let (ip, port) = extractIPPort(from: addr), port > 0 {
                let priority = addressPriority(ip: ip)
                validAddresses.append((address: makeAddress(ip: ip, port: port), ip: ip, port: port, priority: priority))
            }
        }
        
        // 按优先级排序（优先级数字越小越好）
        validAddresses.sort { $0.priority < $1.priority }
        
        if let bestAddress = validAddresses.first {
            if validAddresses.count > 1 && bestAddress.priority == 2 {
                // 如果最佳地址是链路本地地址，但还有其他地址，给出警告
                print("[AddressConverter] ⚠️ 选择链路本地地址 \(bestAddress.ip)，但存在 \(validAddresses.count - 1) 个其他地址")
            }
            return bestAddress.address
        }
        
        // 只有在所有地址都无效时才输出错误日志
        if !addresses.isEmpty {
            print("[AddressConverter] ❌ 没有找到有效地址（共检查 \(addresses.count) 个地址）")
        }
        return nil
    }
    
    /// 获取所有有效地址（按优先级排序）
    /// 用于地址回退机制：如果第一个地址失败，可以尝试其他地址
    public static func extractAllAddresses(from addresses: [String]) -> [String] {
        var validAddresses: [(address: String, ip: String, port: UInt16, priority: Int)] = []
        
        for addr in addresses {
            if let (ip, port) = extractIPPort(from: addr), port > 0 {
                let priority = addressPriority(ip: ip)
                validAddresses.append((address: makeAddress(ip: ip, port: port), ip: ip, port: port, priority: priority))
            }
        }
        
        // 按优先级排序
        validAddresses.sort { $0.priority < $1.priority }
        
        return validAddresses.map { $0.address }
    }
}
