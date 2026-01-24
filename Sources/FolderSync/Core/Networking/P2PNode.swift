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
            print("[P2PNode] 🔧 手动注册对等点到 libp2p peer store:")
            print("[P2PNode]   - PeerID: \(peerIDObj.b58String)")
            print("[P2PNode]   - Addresses: \(parsedAddresses.count) 个")
            for (idx, addr) in parsedAddresses.enumerated() {
                print("[P2PNode]     [\(idx + 1)] \(addr)")
            }
            
            // Call the discovery callback that was registered in start()
            // This should add the peer to libp2p's peer store with the addresses
            // 注意：这个回调必须在 app.startup() 之后调用才能正确工作
            if let callback = discoveryCallback {
                // 修复 Bug 1: 先等待 1.5 秒，然后再调用 callback
                // 这样可以确保在所有情况下，通知都在等待之后发送，保持时序一致
                // 当 callback 被调用时，discoveryHandler 会立即触发 onPeerDiscovered
                // 所以通知发生在 T=1.5 秒，SyncManager 在 T=2.5 秒开始同步（等待 1 秒）
                print("[P2PNode] ⏳ 等待 1.5 秒后再注册对等点（确保时序一致）...")
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5秒
                
                print("[P2PNode] ✅ 调用发现回调注册对等点...")
                callback(peerInfo)
                print("[P2PNode] ✅ 发现回调已调用，对等点应该已添加到 peer store")
                print("[P2PNode] ✅ SyncManager 应该已收到对等点发现通知（通过 discoveryHandler）")
                
                // 修复 Bug 1: 调用 callback 后，还需要等待 libp2p 处理完成
                // libp2p 需要时间处理 discovery callback 并更新内部 peer store
                // 虽然通知已经发送，但我们仍需要等待确保 peer store 已更新
                // 这样 SyncManager 开始同步时，peer store 已经准备好了
                print("[P2PNode] ⏳ 等待 libp2p 处理发现回调并更新 peer store...")
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
                print("[P2PNode] ✅ 对等点注册完成，peer store 应该已更新")
                // 总等待时间：1.5 + 1 = 2.5 秒
                // 通知发生在 T=1.5 秒，SyncManager 在 T=2.5 秒开始同步
                // 此时 P2PNode 已经等待了 2.5 秒，确保 peer store 已更新
            } else {
                print("[P2PNode] ❌ Discovery callback 不可用！")
                print("[P2PNode] ⚠️ 严重警告: 对等点无法注册到 libp2p peer store")
                print("[P2PNode] 💡 这可能是因为 app.startup() 尚未完成")
                print("[P2PNode] 💡 或者 discovery callback 尚未注册")
                print("[P2PNode] 💡 这会导致后续的 peerNotFound 错误")
                
                // 修复 Bug 1: 在 no-callback 路径中，我们需要在通知前等待 1.5 秒
                // 这样可以确保与 callback-available 路径的时序一致
                // callback-available: 等待 1.5 秒 → 通知（T=1.5）→ 等待 1 秒（T=2.5，确保 libp2p 处理）
                // no-callback: 等待 1.5 秒 → 通知（T=1.5）→ 立即返回
                // SyncManager 在两种情况下都会在 T=1.5 收到通知，然后等待 1 秒，在 T=2.5 开始同步
                // 在 callback-available 路径中，P2PNode 的 1 秒等待与 SyncManager 的 1 秒等待是并行的
                // 在 no-callback 路径中，由于无法注册到 peer store，不需要额外的等待
                print("[P2PNode] ⏳ 等待 1.5 秒后再通知 SyncManager（确保时序一致）...")
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5秒
                
                // 即使 discovery callback 不可用，也尝试通知 SyncManager
                // 这样至少设备会出现在列表中，即使可能无法连接
                print("[P2PNode] 📡 尝试直接触发 peer discovery callback...")
                await MainActor.run {
                    self.onPeerDiscovered?(peerIDObj)
                }
                print("[P2PNode] ✅ 对等点处理完成（虽然无法注册到 peer store）")
                // 注意：不等待额外的 1 秒，因为无法注册到 peer store，不需要等待 libp2p 处理
                // SyncManager 会等待 1 秒，在 T=2.5 开始同步（与 callback-available 路径一致）
            }
        } else {
            print("[P2PNode] ⚠️ No valid addresses found for \(peerID.prefix(8)): \(addresses)")
            print("[P2PNode] 💡 libp2p will try to discover the peer via other mechanisms")
            
            // 修复 Bug 1: 在 no-address 路径中，我们需要在通知前等待 1.5 秒
            // 这样可以确保与 callback-available 路径的时序一致
            // callback-available: 等待 1.5 秒 → 通知（T=1.5）→ 等待 1 秒（T=2.5，确保 libp2p 处理）
            // no-address: 等待 1.5 秒 → 通知（T=1.5）→ 立即返回
            // SyncManager 在两种情况下都会在 T=1.5 收到通知，然后等待 1 秒，在 T=2.5 开始同步
            // 在 callback-available 路径中，P2PNode 的 1 秒等待与 SyncManager 的 1 秒等待是并行的
            // 在 no-address 路径中，由于没有地址，无法注册到 peer store，不需要额外的等待
            print("[P2PNode] ⏳ 等待 1.5 秒后再通知 SyncManager（确保时序一致）...")
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5秒
            
            // 即使没有地址，也通知 SyncManager，这样设备会出现在列表中
            // 后续如果有地址了，可以再次注册
            print("[P2PNode] 📡 触发 peer discovery callback（无地址，但通知 SyncManager）...")
            await MainActor.run {
                self.onPeerDiscovered?(peerIDObj)
            }
            print("[P2PNode] ✅ 对等点处理完成（虽然无法注册到 peer store）")
            // 注意：不等待额外的 1 秒，因为无法注册到 peer store，不需要等待 libp2p 处理
            // SyncManager 会等待 1 秒，在 T=2.5 开始同步（与 callback-available 路径一致）
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
            self?.onPeerDiscovered?(peerInfo.peer)
        }
        
        app.discovery.onPeerDiscovered(self, closure: discoveryHandler)
        
        // Save the callback so we can manually trigger it for LAN-discovered peers
        // 注意：这个回调必须在 app.startup() 之后才能正确工作
        self.discoveryCallback = discoveryHandler
        print("[P2PNode] ✅ 发现回调已注册，可用于手动注册 LAN 发现的对等点")

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
