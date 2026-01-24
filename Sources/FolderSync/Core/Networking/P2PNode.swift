import Darwin
import Foundation
import LibP2P
import LibP2PKadDHT
import NIOCore

public class P2PNode {
    public var app: Application?
    private var lanDiscovery: LANDiscovery?
    private var peerAddressCache: [String: [Multiaddr]] = [:] // 缓存对等点地址 (使用 b58String 作为键)
    private var registeringPeers: Set<String> = [] // 正在注册的对等点 PeerID (b58String)，用于去重
    private var registeredPeers: Set<String> = [] // 已成功注册到 peer store 的对等点 PeerID (b58String)
    private let registeredPeersQueue = DispatchQueue(label: "com.foldersync.p2pnode.registeredpeers", attributes: .concurrent)

    public init() {}
    
    /// 获取对等点的缓存地址
    func getCachedAddresses(for peer: PeerID) -> [Multiaddr]? {
        return peerAddressCache[peer.b58String]
    }
    
    /// 检查对等点是否已成功注册到 peer store
    func isPeerRegistered(_ peerID: String) -> Bool {
        return registeredPeersQueue.sync {
            return registeredPeers.contains(peerID)
        }
    }
    
    /// 标记对等点为已注册（线程安全）
    private func markPeerAsRegistered(_ peerID: String) {
        registeredPeersQueue.async(flags: .barrier) {
            self.registeredPeers.insert(peerID)
        }
    }
    
    /// Setup LAN discovery using UDP broadcast
    private func setupLANDiscovery(peerID: String, listenAddresses: [String] = []) {
        let discovery = LANDiscovery()
        discovery.onPeerDiscovered = { [weak self] discoveredPeerID, address, peerAddresses in
            print("[P2PNode] 🔍 LAN discovery found peer:")
            print("[P2PNode]   - PeerID (完整): \(discoveredPeerID)")
            print("[P2PNode]   - PeerID (长度): \(discoveredPeerID.count) 字符")
            print("[P2PNode]   - 发现地址: \(address)")
            print("[P2PNode]   - 监听地址数量: \(peerAddresses.count)")
            for (idx, addr) in peerAddresses.enumerated() {
                print("[P2PNode]     [\(idx + 1)] \(addr)")
            }
            
            // 验证 PeerID 格式
            if discoveredPeerID.isEmpty {
                print("[P2PNode] ❌ 错误: 发现的 PeerID 为空")
                return
            }
            
            if discoveredPeerID.count < 10 {
                print("[P2PNode] ⚠️ 警告: 发现的 PeerID 似乎过短: \(discoveredPeerID)")
            }
            
            // Try to connect to the discovered peer via libp2p
            Task { @MainActor in
                await self?.connectToDiscoveredPeer(peerID: discoveredPeerID, addresses: peerAddresses)
            }
        }
        discovery.start(peerID: peerID, listenAddresses: listenAddresses)
        self.lanDiscovery = discovery
        print("[P2PNode] LAN discovery enabled using UDP broadcast. Automatic peer discovery active.")
    }
    
    /// Connect to a peer discovered via LAN discovery
    private func connectToDiscoveredPeer(peerID: String, addresses: [String]) async {
        guard let app = app else {
            print("[P2PNode] ⚠️ App not initialized, cannot connect to peer")
            return
        }
        
        // 验证输入的 PeerID
        print("[P2PNode] 🔧 尝试连接对等点:")
        print("[P2PNode]   - 输入 PeerID: \(peerID)")
        print("[P2PNode]   - PeerID 长度: \(peerID.count) 字符")
        
        if peerID.isEmpty {
            print("[P2PNode] ❌ 错误: PeerID 为空，无法连接")
            return
        }
        
        // 检查是否已经成功注册过此对等点（线程安全）
        let isAlreadyRegistered = self.isPeerRegistered(peerID)
        
        // 如果已经注册过，且这次有地址，检查地址是否有更新
        if isAlreadyRegistered && !addresses.isEmpty {
            // 解析新地址
            var newAddresses: [Multiaddr] = []
            for addressStr in addresses {
                if let multiaddr = try? Multiaddr(addressStr) {
                    newAddresses.append(multiaddr)
                }
            }
            
            // 检查是否有新地址
            let cachedAddresses = await MainActor.run {
                return self.peerAddressCache[peerID] ?? []
            }
            
            // 如果地址相同，跳过
            if Set(newAddresses.map { $0.description }) == Set(cachedAddresses.map { $0.description }) {
                print("[P2PNode] ⏭️ 对等点 \(peerID.prefix(12))... 已注册且地址未变化，跳过")
                return
            }
            
            // 地址有更新，继续注册流程
            print("[P2PNode] 🔄 对等点 \(peerID.prefix(12))... 地址已更新，重新注册")
        }
        
        // 检查是否正在注册此对等点（去重）
        let isRegistering = await MainActor.run {
            if self.registeringPeers.contains(peerID) {
                return true
            }
            // 标记为正在注册
            self.registeringPeers.insert(peerID)
            return false
        }
        
        if isRegistering {
            print("[P2PNode] ⏭️ 对等点 \(peerID.prefix(12))... 正在注册中，跳过重复注册")
            return
        }
        
        // 使用 defer 确保在函数返回时移除注册标记
        defer {
            Task { @MainActor in
                self.registeringPeers.remove(peerID)
            }
        }
        
        // Try to parse the peerID string to PeerID object
        let peerIDObj: PeerID
        do {
            peerIDObj = try PeerID(cid: peerID)
            let parsedPeerIDString = peerIDObj.b58String
            print("[P2PNode] ✅ PeerID 解析成功:")
            print("[P2PNode]   - 解析后的 PeerID (完整): \(parsedPeerIDString)")
            print("[P2PNode]   - 解析后的 PeerID 长度: \(parsedPeerIDString.count) 字符")
            
            // 验证 PeerID 长度（正常的 libp2p PeerID 应该是 50+ 字符）
            if parsedPeerIDString.count < 40 {
                print("[P2PNode] ⚠️ 警告: PeerID 长度异常短，可能不完整")
            }
            
            // 验证解析后的 PeerID 是否与输入一致
            if parsedPeerIDString != peerID {
                print("[P2PNode] ⚠️ 警告: 解析后的 PeerID 与输入不一致!")
                print("[P2PNode]   输入: \(peerID)")
                print("[P2PNode]   解析: \(parsedPeerIDString)")
            }
        } catch {
            print("[P2PNode] ❌ Failed to parse peerID: \(peerID)")
            print("[P2PNode]   错误详情: \(error.localizedDescription)")
            print("[P2PNode]   PeerID 可能格式不正确或已损坏")
            print("[P2PNode]   期望格式: base58 编码的 PeerID (通常 50+ 字符)")
            return
        }
        
        // Parse and add addresses to libp2p's peer store
        var parsedAddresses: [Multiaddr] = []
        for addressStr in addresses {
            if let multiaddr = try? Multiaddr(addressStr) {
                parsedAddresses.append(multiaddr)
                print("[P2PNode] ✅ Parsed address for \(peerID.prefix(8)): \(multiaddr)")
            } else {
                print("[P2PNode] ⚠️ Could not parse address: \(addressStr)")
            }
        }
        
        // libp2p needs the peer addresses in its peer store to connect
        // The key issue: newRequest requires addresses to be in peer store, but we discovered
        // the peer via LANDiscovery, not libp2p's discovery mechanisms
        // 
        // Solution: We need to manually add the peer to libp2p's peer store
        // Unfortunately, swift-libp2p may not expose peerStore API directly
        // We'll try to trigger libp2p's internal mechanisms by making a connection attempt
        
        if !parsedAddresses.isEmpty {
            print("[P2PNode] ✅ Found \(parsedAddresses.count) address(es) for \(peerID.prefix(8))")
            for addr in parsedAddresses {
                print("[P2PNode]   - \(addr)")
            }
            
            // Store addresses in cache
            await MainActor.run {
                peerAddressCache[peerIDObj.b58String] = parsedAddresses
            }
            
            // 自动注册机制：直接通知 SyncManager，让 libp2p 通过其自身的 discovery 机制自动发现和注册 peer
            // 注意：LANDiscovery 发现的 peer 不会自动添加到 libp2p 的 peer store
            // 但我们可以通过以下方式让 libp2p 自动发现：
            // 1. 使用 discovery.announce 让其他设备发现我们
            // 2. 配置 DHT 让 libp2p 自动发现 peer
            // 3. 在 SyncManager 中处理 peerNotFound 错误，通过重试等待 libp2p 自动发现
            print("[P2PNode] 🔍 发现对等点，等待 libp2p 自动注册:")
            print("[P2PNode]   - PeerID: \(peerIDObj.b58String)")
            print("[P2PNode]   - Addresses: \(parsedAddresses.count) 个")
            for (idx, addr) in parsedAddresses.enumerated() {
                print("[P2PNode]     [\(idx + 1)] \(addr)")
            }
            
            // 尝试使用 libp2p 的 discovery.announce 机制来让 libp2p 自动发现和注册 peer
            // 使用对等点的地址创建一个服务标识符
            // 这样 libp2p 可能会自动发现并注册这个 peer
            let serviceName = "folder-sync-\(peerIDObj.b58String.prefix(8))"
            print("[P2PNode] 📡 尝试通过 discovery.announce 让 libp2p 自动发现对等点...")
            do {
                _ = try? await app.discovery.announce(.service(serviceName)).get()
                print("[P2PNode] ✅ Discovery announce 已发送")
            } catch {
                print("[P2PNode] ⚠️ Discovery announce 失败（可能不影响功能）: \(error.localizedDescription)")
            }
            
            // 等待一小段时间，让 libp2p 有机会自动发现和注册 peer
            print("[P2PNode] ⏳ 等待 libp2p 自动发现和注册对等点...")
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
            
            // 直接通知 SyncManager 发现的 peer
            // SyncManager 会在同步时处理 peerNotFound 错误，通过重试等待 libp2p 自动发现
            print("[P2PNode] 📡 通知 SyncManager 对等点已发现...")
            await MainActor.run {
                self.onPeerDiscovered?(peerIDObj)
            }
            print("[P2PNode] ✅ SyncManager 已收到对等点发现通知")
            
            // 注意：我们不会立即标记为"已注册"，因为 libp2p 可能还没有自动发现这个 peer
            // 实际的注册状态会在 SyncManager 尝试同步时通过 peerNotFound 错误来判断
            // 如果 libp2p 成功自动发现并注册了 peer，后续的同步请求会成功
        } else {
            print("[P2PNode] ⚠️ No valid addresses found for \(peerID.prefix(8)): \(addresses)")
            print("[P2PNode] 💡 无法注册对等点到 peer store（缺少地址）")
            print("[P2PNode] 💡 等待后续发现时提供地址后再注册")
            
            // 如果没有地址，不应该通知 SyncManager，因为无法注册到 peer store
            // 这会导致 SyncManager 尝试同步但失败（peerNotFound）
            // 只有当有地址时，才通知 SyncManager
            print("[P2PNode] ⏭️ 跳过通知 SyncManager（无地址，无法注册）")
            print("[P2PNode] 💡 当后续 LAN discovery 提供地址时，会再次尝试注册")
        }
    }

    public var onPeerDiscovered: ((PeerID) -> Void)?
    public func start() async throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folderSyncDir = appSupport.appendingPathComponent("FolderSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderSyncDir, withIntermediateDirectories: true)
        
        let password = KeychainManager.loadOrCreatePassword()
        let keyPairFile: KeyPairFile = .persistent(
            type: .Ed25519,
            encryptedWith: .password(password),
            storedAt: .filePath(folderSyncDir)
        )
        
        // 尝试创建 Application，如果失败（通常是密钥文件解密失败），删除旧文件并重试
        var app: Application
        do {
            app = try await Application.make(.development, peerID: keyPairFile)
        } catch {
            print("[P2PNode] ⚠️ 警告: 无法加载现有密钥对文件: \(error.localizedDescription)")
            print("[P2PNode] 这通常是因为密钥文件损坏或密码不匹配")
            print("[P2PNode] 尝试删除旧的密钥文件并重新生成...")
            
            // 删除整个目录并重新创建，确保彻底清理所有密钥相关文件
            let fileManager = FileManager.default
            do {
                // 尝试删除整个目录
                if fileManager.fileExists(atPath: folderSyncDir.path) {
                    try fileManager.removeItem(at: folderSyncDir)
                    print("[P2PNode] 已删除旧的 FolderSync 目录")
                }
                // 重新创建目录
                try fileManager.createDirectory(at: folderSyncDir, withIntermediateDirectories: true)
                print("[P2PNode] 已重新创建 FolderSync 目录")
            } catch {
                print("[P2PNode] ⚠️ 删除目录时出错: \(error.localizedDescription)")
                // 如果删除目录失败，尝试删除目录内的所有文件
                if let files = try? fileManager.contentsOfDirectory(at: folderSyncDir, includingPropertiesForKeys: nil) {
                    for file in files {
                        try? fileManager.removeItem(at: file)
                        print("[P2PNode] 已删除文件: \(file.lastPathComponent)")
                    }
                }
            }
            
            // 重新生成密码（确保使用新密码）
            let newPassword = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32).description
            _ = KeychainManager.savePassword(newPassword)
            print("[P2PNode] 已生成新密码并保存到文件")
            
            // 使用新密码创建新的密钥文件
            let newKeyPairFile: KeyPairFile = .persistent(
                type: .Ed25519,
                encryptedWith: .password(newPassword),
                storedAt: .filePath(folderSyncDir)
            )
            
            // 重试创建 Application
            do {
                app = try await Application.make(.development, peerID: newKeyPairFile)
                print("[P2PNode] ✅ 成功创建新的密钥对文件")
            } catch {
                print("[P2PNode] ❌ 错误: 即使删除旧文件后仍无法创建新的密钥对: \(error.localizedDescription)")
                throw error
            }
        }
        
        self.app = app

        // Explicitly configure TCP to listen on all interfaces
        // Using port 0 allows the OS to assign any available port
        app.listen(.tcp(host: "0.0.0.0", port: 0))

        // Enable LAN discovery using UDP broadcast (more reliable than mDNS)
        // 这是主要的设备发现机制，完全在局域网内工作，无需任何服务器
        // Will update addresses after startup
        setupLANDiscovery(peerID: app.peerID.b58String, listenAddresses: [])

        // 注意：DHT 是可选的，主要用于广域网发现
        // 如果只需要局域网同步，可以注释掉以下 DHT 配置
        // 当前保留 DHT 以支持未来可能的广域网功能，但局域网同步完全依赖 LANDiscovery
        // app.discovery.use(.kadDHT)
        // print("[P2PNode] ✅ Kademlia DHT 已配置为发现服务（可选，用于广域网）")
        
        // 也可以将 DHT 作为独立的 DHT 使用（用于值存储和检索）
        // app.dht.use(.kadDHT)
        
        // TODO: AutoNAT 和 Circuit Relay - 需要配置:
        // app.use(.autonat)
        // app.use(.circuitRelay(...))
        // 需要检查 swift-libp2p 是否提供这些模块
        
        // Register for peer discovery events (from libp2p's discovery mechanisms)
        // When libp2p discovers a peer (via DHT or other mechanisms), it will call this callback
        // The PeerInfo includes addresses, which libp2p automatically adds to the peer store
        let discoveryHandler: (PeerInfo) -> Void = { [weak self] (peerInfo: PeerInfo) in
            print("[P2PNode] 📡 libp2p 发现对等点:")
            print("[P2PNode]   - PeerID: \(peerInfo.peer.b58String)")
            print("[P2PNode]   - Addresses: \(peerInfo.addresses.count) 个")
            for (idx, addr) in peerInfo.addresses.enumerated() {
                print("[P2PNode]     [\(idx + 1)] \(addr)")
            }
            print("[P2PNode] ✅ libp2p 已将对等点添加到 peer store（包含地址）")
            // libp2p has already added this peer to the peer store with addresses
            // 标记为已成功注册（线程安全）
            self?.markPeerAsRegistered(peerInfo.peer.b58String)
            self?.onPeerDiscovered?(peerInfo.peer)
        }
        
        app.discovery.onPeerDiscovered(self, closure: discoveryHandler)
        print("[P2PNode] ✅ 发现回调已注册，libp2p 会自动处理发现的对等点")

        // Start the application and wait for it to complete
        // 必须等待 startup 完成，否则 discovery callback 可能无法正确工作
        do {
            try await app.startup()
            print("[P2PNode] ✅ libp2p 应用启动完成，peer store 已就绪")
        } catch {
            print("[P2PNode] ❌ Critical failure during startup: \(error)")
            throw error
        }

        // Give the node a moment to initialize the server and update listenAddresses
        try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s

        // Update LAN discovery with actual listen addresses
        let addresses = app.listenAddresses.map { $0.description }
        lanDiscovery?.updateListenAddresses(addresses)
        
        // 地址更新后，立即发送一次广播，让其他设备知道我们的地址
        // 这对于新启动的设备特别重要，可以立即被已有设备发现
        if !addresses.isEmpty {
            print("[P2PNode] 📡 监听地址已更新，立即广播以通知其他设备...")
            // 延迟一小段时间确保地址已完全更新，然后发送发现请求
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) { [weak self] in
                // 发送发现请求，主动寻找已有设备
                self?.lanDiscovery?.sendDiscoveryRequest()
            }
        }

        // 详细日志输出
        print("\n[P2PNode] ========== P2P 节点启动状态 ==========")
        print("[P2PNode] PeerID: \(app.peerID.b58String)")
        print("[P2PNode] 监听地址数量: \(app.listenAddresses.count)")
        
        if app.listenAddresses.isEmpty {
            print("[P2PNode] ⚠️ 警告: 未检测到监听地址，libp2p 可能未成功启动")
            print("[P2PNode] 请检查:")
            print("[P2PNode]   1. 网络权限是否已授予")
            print("[P2PNode]   2. 防火墙是否阻止了端口")
            print("[P2PNode]   3. 是否有其他程序占用了端口")
        } else {
            print("[P2PNode] ✅ 监听地址列表:")
            for (index, addr) in app.listenAddresses.enumerated() {
                print("[P2PNode]   [\(index + 1)] \(addr)")
            }
            print("[P2PNode] ✅ Ready for connections. Listening on: \(app.listenAddresses)")
        }
        
        // 检查 LANDiscovery 状态
        if let discovery = lanDiscovery {
            print("[P2PNode] ✅ LAN Discovery 已启用 (UDP 广播端口: 8765)")
            print("[P2PNode] ✅ 局域网发现已启用，使用 UDP 广播自动发现同一网络内的设备")
            print("[P2PNode] ℹ️ 所有通信均在客户端之间直接进行，无需任何服务器端")
        } else {
            print("[P2PNode] ❌ LAN Discovery 未启用")
            print("[P2PNode] ⚠️ 警告: 局域网发现功能未启动，设备将无法自动发现其他设备")
            print("[P2PNode] 💡 提示: 这可能是初始化失败，请检查日志中的错误信息")
        }
        
        print("[P2PNode] ======================================\n")
    }

    public func announce(service: String) async throws {
        guard let app = app else { return }
        // Announce a service (like a sync group ID) on the network
        _ = try await app.discovery.announce(.service(service)).get()
        print("Announced service: \(service)")
    }

    public func stop() async throws {
        lanDiscovery?.stop()
        try await app?.asyncShutdown()
    }

    public var peerID: String? {
        app?.peerID.b58String
    }

    public var listenAddresses: [String] {
        app?.listenAddresses.map { $0.description } ?? []
    }
}
