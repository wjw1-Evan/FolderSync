import Foundation

/// 持久化的 Peer 信息（用于序列化）
struct PersistentPeerInfo: Codable {
    let peerIDString: String
    let addresses: [String] // Multiaddr 的字符串表示
    let isRegistered: Bool
    let discoveryTime: Date
    let lastSeenTime: Date
    
    init(from peerInfo: PeerInfo) {
        self.peerIDString = peerInfo.peerIDString
        self.addresses = peerInfo.addresses.map { $0.description }
        self.isRegistered = peerInfo.isRegistered
        self.discoveryTime = peerInfo.discoveryTime
        self.lastSeenTime = peerInfo.lastSeenTime
    }
}

/// 持久化 Peer Store 管理器
public class PersistentPeerStore {
    public static let shared = PersistentPeerStore()
    
    private let fileManager = FileManager.default
    private var peersFile: URL {
        return AppPaths.appDirectory.appendingPathComponent("peers.json")
    }
    
    private init() {
        // 确保目录存在
        let folderSyncDir = peersFile.deletingLastPathComponent()
        try? fileManager.createDirectory(at: folderSyncDir, withIntermediateDirectories: true)
    }
    
    /// 保存 peer 信息到文件
    func savePeers(_ peers: [String: PeerInfo]) throws {
        let persistentPeers = peers.values.map { PersistentPeerInfo(from: $0) }
        let data = try JSONEncoder().encode(persistentPeers)
        try data.write(to: peersFile, options: [.atomic])
        print("[PersistentPeerStore] ✅ 已保存 \(persistentPeers.count) 个 peer 到文件")
    }
    
    /// 从文件加载 peer 信息
    func loadPeers() throws -> [PersistentPeerInfo] {
        guard fileManager.fileExists(atPath: peersFile.path) else {
            print("[PersistentPeerStore] ℹ️ Peer 存储文件不存在，返回空列表")
            return []
        }
        
        guard let data = try? Data(contentsOf: peersFile) else {
            print("[PersistentPeerStore] ⚠️ 无法读取 peer 存储文件")
            return []
        }
        
        do {
            let peers = try JSONDecoder().decode([PersistentPeerInfo].self, from: data)
            print("[PersistentPeerStore] ✅ 成功加载 \(peers.count) 个 peer")
            return peers
        } catch {
            print("[PersistentPeerStore] ❌ 解析 peer 存储文件失败: \(error)")
            // 备份损坏的文件
            let backupFile = peersFile.appendingPathExtension("corrupted.\(Int(Date().timeIntervalSince1970)).backup")
            try? data.write(to: backupFile, options: [.atomic])
            print("[PersistentPeerStore] 💾 已备份损坏的文件到: \(backupFile.lastPathComponent)")
            return []
        }
    }
    
    /// 将持久化的 peer 信息转换为 PeerInfo（需要 PeerID 对象）
    func convertToPeerInfo(_ persistent: PersistentPeerInfo) -> (peerID: PeerID, addresses: [Multiaddr], isRegistered: Bool)? {
        // 解析 PeerID
        guard let peerID = PeerID(cid: persistent.peerIDString) else {
            print("[PersistentPeerStore] ⚠️ 无法解析 PeerID: \(persistent.peerIDString)")
            return nil
        }
        
        // 解析地址
        var addresses: [Multiaddr] = []
        for addrStr in persistent.addresses {
            if let addr = try? Multiaddr(addrStr) {
                addresses.append(addr)
            } else {
                print("[PersistentPeerStore] ⚠️ 无法解析地址: \(addrStr)")
            }
        }
        
        return (peerID: peerID, addresses: addresses, isRegistered: persistent.isRegistered)
    }
}
