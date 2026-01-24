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
        
        guard !addresses.isEmpty else {
            print("[P2PNode] ⚠️ 重试注册失败: 对等点无可用地址: \(peerIDString.prefix(12))...")
            return
        }
        
        guard let handler = discoveryHandler else {
            print("[P2PNode] ⚠️ 重试注册失败: discoveryHandler 未设置: \(peerIDString.prefix(12))...")
            return
        }
        
        let peerInfo = LibP2P.PeerInfo(peer: peer, addresses: addresses)
        handler(peerInfo)
        print("[P2PNode] 🔄 已重新注册: \(peerIDString.prefix(12))... (\(addresses.count) 个地址)")
        
        // 等待足够的时间确保 libp2p 内部完成注册
        // libp2p 需要时间将 peer 添加到 peer store 并建立连接
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 增加到 2 秒
        
        // 更新注册状态
        await MainActor.run {
            peerManager.markAsRegistered(peerIDString)
        }
        
        print("[P2PNode] ✅ 重试注册完成: \(peerIDString.prefix(12))...")
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
            guard !discoveredPeerID.isEmpty else {
                print("[P2PNode] ⚠️ 收到空的 peerID，忽略")
                return
            }
            
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                // 确保 discoveryHandler 已设置
                if self.discoveryHandler == nil {
                    print("[P2PNode] ⚠️ discoveryHandler 未设置，延迟处理对等点: \(discoveredPeerID.prefix(12))...")
                    // 延迟重试
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if self.discoveryHandler == nil {
                        print("[P2PNode] ❌ discoveryHandler 仍未设置，无法注册对等点: \(discoveredPeerID.prefix(12))...")
                        return
                    }
                }
                
                await self.connectToDiscoveredPeer(peerID: discoveredPeerID, discoveryAddress: address, listenAddresses: peerAddresses)
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
        guard app != nil, !peerID.isEmpty else {
            print("[P2PNode] ⚠️ 注册失败: app 未初始化或 peerID 为空")
            return
        }
        
        // 检查 discoveryHandler 是否已设置
        if discoveryHandler == nil {
            print("[P2PNode] ⚠️ 注册失败: discoveryHandler 未设置，等待初始化完成...")
            // 等待一小段时间后重试
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if discoveryHandler == nil {
                print("[P2PNode] ❌ 注册失败: discoveryHandler 仍未设置")
                return
            }
        }
        
        // 去重：检查是否正在注册
        let shouldSkip = await MainActor.run {
            return !peerManager.startRegistering(peerID)
        }
        
        if shouldSkip {
            print("[P2PNode] ⏭️ 对等点正在注册中，跳过: \(peerID.prefix(12))...")
            return
        }
        
        defer {
            Task { @MainActor in
                peerManager.finishRegistering(peerID)
            }
        }
        
        print("[P2PNode] 🔄 开始注册对等点: \(peerID.prefix(12))...")
        print("[P2PNode]   发现地址: \(discoveryAddress)")
        print("[P2PNode]   监听地址数量: \(listenAddresses.count)")
        
        // 解析 PeerID
        guard let peerIDObj = try? PeerID(cid: peerID) else {
            print("[P2PNode] ❌ 注册失败: 无法解析 PeerID: \(peerID.prefix(12))...")
            print("[P2PNode]   PeerID 长度: \(peerID.count) 字符")
            return
        }
        
        // 生成可连接地址
        let connectableStrs = Self.buildConnectableAddresses(listenAddresses: listenAddresses, discoveryAddress: discoveryAddress)
        print("[P2PNode]   可连接地址数量: \(connectableStrs.count)")
        
        var parsedAddresses: [Multiaddr] = []
        var parseErrors: [String] = []
        for addrStr in connectableStrs {
            if let addr = try? Multiaddr(addrStr) {
                parsedAddresses.append(addr)
            } else {
                parseErrors.append(addrStr)
            }
        }
        
        if !parseErrors.isEmpty {
            print("[P2PNode] ⚠️ 部分地址解析失败:")
            for errAddr in parseErrors {
                print("[P2PNode]   - \(errAddr)")
            }
        }
        
        guard !parsedAddresses.isEmpty else {
            print("[P2PNode] ❌ 注册失败: 无有效地址")
            print("[P2PNode]   原始监听地址: \(listenAddresses)")
            print("[P2PNode]   可连接地址: \(connectableStrs)")
            return
        }
        
        print("[P2PNode]   成功解析 \(parsedAddresses.count) 个地址:")
        for (idx, addr) in parsedAddresses.enumerated() {
            print("[P2PNode]     [\(idx + 1)] \(addr)")
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
                if !addressesChanged {
                    print("[P2PNode] ⏭️ 对等点已注册且地址未变化，跳过: \(peerID.prefix(12))...")
                }
                return addressesChanged
            }
            return true
        }
        
        guard shouldRegister else {
            return
        }
        
        // 注册 peer 到 libp2p
        guard let handler = discoveryHandler else {
            print("[P2PNode] ❌ 注册失败: discoveryHandler 为 nil")
            return
        }
        
        let libp2pPeerInfo = LibP2P.PeerInfo(peer: peerIDObj, addresses: parsedAddresses)
        handler(libp2pPeerInfo)
        print("[P2PNode] ✅ 已调用 discoveryHandler 注册对等点")
        
        // 等待足够的时间确保 libp2p 内部完成注册
        // libp2p 需要时间将 peer 添加到 peer store 并建立连接
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 增加到 2 秒
        
        // 标记为已注册
        await MainActor.run {
            peerManager.markAsRegistered(peerID)
        }
        
        // 通知 SyncManager（延迟通知，确保注册完成）
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
