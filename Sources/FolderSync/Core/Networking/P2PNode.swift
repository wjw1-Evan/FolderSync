import Darwin
import Foundation
import LibP2P
import LibP2PKadDHT
import NIOCore

public class P2PNode {
    public var app: Application?
    private var lanDiscovery: LANDiscovery?
    private var discoveryHandler: ((LibP2P.PeerInfo) -> Void)? // 保存 discovery handler 以便手动触发
    @MainActor public let peerManager: PeerManager // 统一的 Peer 管理器

    public init() {
        // PeerManager 需要在 MainActor 上初始化
        self.peerManager = MainActor.assumeIsolated { PeerManager() }
    }
    
    /// 获取对等点的缓存地址
    func getCachedAddresses(for peer: PeerID) async -> [Multiaddr]? {
        return await MainActor.run {
            return peerManager.getAddresses(for: peer.b58String)
        }
    }
    
    /// 重新触发对等点注册（用于 peerNotFound 错误后的重试）
    func retryPeerRegistration(peer: PeerID) async {
        let peerIDString = peer.b58String
        let addresses = await MainActor.run {
            return peerManager.getAddresses(for: peerIDString)
        }
        
        guard !addresses.isEmpty else { return }
        
        let peerInfo = LibP2P.PeerInfo(peer: peer, addresses: addresses)
        discoveryHandler?(peerInfo)
        print("[P2PNode] 🔄 已重新注册: \(peerIDString.prefix(12))...")
    }
    
    /// 检查对等点是否已成功注册到 peer store
    func isPeerRegistered(_ peerID: String) async -> Bool {
        return await MainActor.run {
            return peerManager.isRegistered(peerID)
        }
    }
    
    /// Setup LAN discovery using UDP broadcast
    private func setupLANDiscovery(peerID: String, listenAddresses: [String] = []) {
        let discovery = LANDiscovery()
        discovery.onPeerDiscovered = { [weak self] discoveredPeerID, address, peerAddresses in
            guard !discoveredPeerID.isEmpty else { return }
            Task { @MainActor in
                await self?.connectToDiscoveredPeer(peerID: discoveredPeerID, discoveryAddress: address, listenAddresses: peerAddresses)
            }
        }
        discovery.start(peerID: peerID, listenAddresses: listenAddresses)
        self.lanDiscovery = discovery
    }
    
    /// 将监听地址中的 0.0.0.0 替换为发现地址的 IP，生成可连接的 multiaddr。
    /// 对等点广播 /ip4/0.0.0.0/tcp/63355 无法直接连接，需替换为 /ip4/192.168.0.164/tcp/63355。
    private static func buildConnectableAddresses(listenAddresses: [String], discoveryAddress: String) -> [String] {
        guard discoveryAddress != "unknown", !discoveryAddress.isEmpty else { return listenAddresses }
        let discoveryIP: String
        if let lastColon = discoveryAddress.lastIndex(of: ":") {
            discoveryIP = String(discoveryAddress[..<lastColon])
        } else {
            discoveryIP = discoveryAddress
        }
        guard !discoveryIP.isEmpty else { return listenAddresses }
        return listenAddresses.map { addr in
            if addr.contains("/ip4/0.0.0.0/") {
                return addr.replacingOccurrences(of: "/ip4/0.0.0.0/", with: "/ip4/\(discoveryIP)/")
            }
            return addr
        }
    }
    
    /// Connect to a peer discovered via LAN discovery
    /// - Parameters:
    ///   - peerID: 对等点 PeerID
    ///   - discoveryAddress: 发现地址，格式为 "IP:port"（如 "192.168.0.164:51262"），用于将 0.0.0.0 替换为可连接 IP
    ///   - listenAddresses: 对等点广播的监听地址（如 /ip4/0.0.0.0/tcp/63355）
    private func connectToDiscoveredPeer(peerID: String, discoveryAddress: String, listenAddresses: [String]) async {
        guard app != nil, !peerID.isEmpty else { return }
        
        // 去重：检查是否正在注册
        let shouldSkip = await MainActor.run {
            return !peerManager.startRegistering(peerID)
        }
        
        if shouldSkip { return }
        
        defer {
            Task { @MainActor in
                peerManager.finishRegistering(peerID)
            }
        }
        
        // 解析 PeerID
        guard let peerIDObj = try? PeerID(cid: peerID) else {
            print("[P2PNode] ❌ 无法解析 PeerID: \(peerID.prefix(12))...")
            return
        }
        
        // 生成可连接地址
        let connectableStrs = Self.buildConnectableAddresses(listenAddresses: listenAddresses, discoveryAddress: discoveryAddress)
        let parsedAddresses = connectableStrs.compactMap { try? Multiaddr($0) }
        
        guard !parsedAddresses.isEmpty else {
            print("[P2PNode] ⚠️ 无有效地址: \(peerID.prefix(12))...")
            return
        }
        
        // 更新或添加 Peer 到管理器
        let peerInfo = await MainActor.run {
            return peerManager.addOrUpdatePeer(peerIDObj, addresses: parsedAddresses)
        }
        
        // 检查是否需要注册（已注册且地址未变化则跳过）
        let shouldRegister = await MainActor.run {
            let existing = peerManager.getPeer(peerID)
            if let existing = existing, existing.isRegistered {
                let addressesChanged = Set(parsedAddresses.map { $0.description }) != Set(existing.addresses.map { $0.description })
                return addressesChanged
            }
            return true
        }
        
        guard shouldRegister else { return }
        
        // 注册 peer 到 libp2p
        let libp2pPeerInfo = LibP2P.PeerInfo(peer: peerIDObj, addresses: parsedAddresses)
        discoveryHandler?(libp2pPeerInfo)
        
        // 标记为已注册
        await MainActor.run {
            peerManager.markAsRegistered(peerID)
        }
        
        // 通知 SyncManager
        await MainActor.run {
            self.onPeerDiscovered?(peerIDObj)
        }
        
        print("[P2PNode] ✅ 对等点已注册: \(peerID.prefix(12))... (\(parsedAddresses.count) 个地址)")
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

        // 启用 LAN discovery（UDP 广播）
        setupLANDiscovery(peerID: app.peerID.b58String, listenAddresses: [])
        
        // 注册 libp2p 的 peer 发现回调
        let discoveryHandler: (LibP2P.PeerInfo) -> Void = { [weak self] (peerInfo: LibP2P.PeerInfo) in
            Task { @MainActor in
                self?.peerManager.addOrUpdatePeer(peerInfo.peer, addresses: peerInfo.addresses)
                self?.peerManager.markAsRegistered(peerInfo.peer.b58String)
            }
            self?.onPeerDiscovered?(peerInfo.peer)
        }
        
        app.discovery.onPeerDiscovered(self, closure: discoveryHandler)
        self.discoveryHandler = discoveryHandler

        // 启动应用
        do {
            try await app.startup()
        } catch {
            print("[P2PNode] ❌ 启动失败: \(error)")
            throw error
        }

        // 等待节点初始化完成
        try? await Task.sleep(nanoseconds: 500_000_000)

        // 更新 LAN discovery 的监听地址
        let addresses = app.listenAddresses.map { $0.description }
        lanDiscovery?.updateListenAddresses(addresses)
        
        // 地址更新后立即发送广播
        if !addresses.isEmpty {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                self?.lanDiscovery?.sendDiscoveryRequest()
            }
        }

        // 输出启动状态
        print("\n[P2PNode] ========== P2P 节点启动状态 ==========")
        print("[P2PNode] PeerID: \(app.peerID.b58String)")
        print("[P2PNode] 监听地址数量: \(app.listenAddresses.count)")
        
        if app.listenAddresses.isEmpty {
            print("[P2PNode] ⚠️ 警告: 未检测到监听地址")
        } else {
            for (index, addr) in app.listenAddresses.enumerated() {
                print("[P2PNode]   [\(index + 1)] \(addr)")
            }
            print("[P2PNode] ✅ Ready for connections")
        }
        
        if lanDiscovery != nil {
            print("[P2PNode] ✅ LAN Discovery 已启用 (UDP 广播端口: 8765)")
        } else {
            print("[P2PNode] ❌ LAN Discovery 未启用")
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
