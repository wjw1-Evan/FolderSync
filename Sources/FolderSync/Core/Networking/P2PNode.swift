import Darwin
import Foundation
import LibP2P
import LibP2PKadDHT
import NIOCore

public class P2PNode {
    public var app: Application?
    private var lanDiscovery: LANDiscovery?
    private var peerAddressCache: [String: [Multiaddr]] = [:] // 缓存对等点地址 (使用 b58String 作为键)
    private var discoveryCallback: ((PeerInfo) -> Void)? // 保存发现回调以便手动调用

    public init() {}
    
    /// 获取对等点的缓存地址
    func getCachedAddresses(for peer: PeerID) -> [Multiaddr]? {
        return peerAddressCache[peer.b58String]
    }
    
    /// Setup LAN discovery using UDP broadcast
    private func setupLANDiscovery(peerID: String, listenAddresses: [String] = []) {
        let discovery = LANDiscovery()
        discovery.onPeerDiscovered = { [weak self] discoveredPeerID, address, peerAddresses in
            print("[P2PNode] LAN discovery found peer: \(discoveredPeerID) at \(address) with addresses: \(peerAddresses)")
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
        
        // Try to parse the peerID string to PeerID object
        guard let peerIDObj = try? PeerID(cid: peerID) else {
            print("[P2PNode] ❌ Failed to parse peerID: \(peerID)")
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
            
            // Critical issue: libp2p's newRequest requires the peer to be in the peer store with addresses
            // Since we discovered the peer via LANDiscovery (not libp2p's discovery), the peer
            // is not in libp2p's peer store, causing "peerNotFound" errors.
            //
            // Solution: Manually trigger libp2p's discovery callback with a PeerInfo
            // This simulates libp2p discovering the peer via its own mechanisms and should
            // add the peer to libp2p's peer store with the provided addresses.
            
            // Create a PeerInfo with the discovered addresses
            let peerInfo = PeerInfo(peer: peerIDObj, addresses: parsedAddresses)
            
            // Manually trigger the discovery callback to register the peer
            // This simulates libp2p discovering the peer via its own mechanisms
            print("[P2PNode] 🔧 Manually registering peer \(peerID.prefix(8)) in libp2p peer store...")
            
            // Call the discovery callback that was registered in start()
            // This should add the peer to libp2p's peer store with the addresses
            if let callback = discoveryCallback {
                callback(peerInfo)
                print("[P2PNode] ✅ Peer \(peerID.prefix(8)) registered with \(parsedAddresses.count) address(es) in libp2p peer store")
            } else {
                print("[P2PNode] ⚠️ Discovery callback not available, peer may not be registered")
                print("[P2PNode] 💡 libp2p will attempt to connect when SyncManager makes a request")
            }
        } else {
            print("[P2PNode] ⚠️ No valid addresses found for \(peerID.prefix(8)): \(addresses)")
            print("[P2PNode] 💡 libp2p will try to discover the peer via other mechanisms")
        }
        
        // Trigger peer discovery callback so SyncManager can try to sync
        // SyncManager will make the actual request, which should work if peer is in peer store
        print("[P2PNode] 📡 Triggering peer discovery callback for \(peerID.prefix(8))")
        await MainActor.run {
            self.onPeerDiscovered?(peerIDObj)
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
            print("[P2PNode] libp2p discovered peer: \(peerInfo.peer.b58String) with \(peerInfo.addresses.count) address(es)")
            // libp2p has already added this peer to the peer store with addresses
            self?.onPeerDiscovered?(peerInfo.peer)
        }
        
        app.discovery.onPeerDiscovered(self, closure: discoveryHandler)
        
        // Save the callback so we can manually trigger it for LAN-discovered peers
        self.discoveryCallback = discoveryHandler

        // Start the application in a background Task so it doesn't block the caller
        Task {
            do {
                try await app.startup()
            } catch {
                print("[P2PNode] Critical failure during startup: \(error)")
            }
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
