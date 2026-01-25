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
    /// 这个函数会立即注册 peer，不等待，让 libp2p 在下次请求时自动建立连接
    func retryPeerRegistration(peer: PeerID) async {
        let peerIDString = peer.b58String
        print("[P2PNode] 🔄 [retryPeerRegistration] 开始重试注册: \(peerIDString.prefix(12))...")
        
        let addresses = await MainActor.run {
            return peerManager.getAddresses(for: peerIDString)
        }
        
        print("[P2PNode] 📍 [retryPeerRegistration] 获取到的地址数量: \(addresses.count)")
        if !addresses.isEmpty {
            for (idx, addr) in addresses.enumerated() {
                print("[P2PNode]   [\(idx + 1)] \(addr)")
            }
        }
        
        guard !addresses.isEmpty else {
            print("[P2PNode] ❌ [retryPeerRegistration] 重试注册失败: 对等点无可用地址: \(peerIDString.prefix(12))...")
            print("[P2PNode] 💡 [retryPeerRegistration] 提示: 对等点可能还未被发现或地址信息丢失")
            return
        }
        
        guard let handler = discoveryHandler else {
            print("[P2PNode] ❌ [retryPeerRegistration] 重试注册失败: discoveryHandler 未设置: \(peerIDString.prefix(12))...")
            return
        }
        
        print("[P2PNode] 🔄 [retryPeerRegistration] 调用 discoveryHandler...")
        let peerInfo = LibP2P.PeerInfo(peer: peer, addresses: addresses)
        handler(peerInfo)
        print("[P2PNode] ✅ [retryPeerRegistration] 已调用 discoveryHandler: \(peerIDString.prefix(12))... (\(addresses.count) 个地址)")
        
        // 不等待，让 libp2p 在下次请求时自动建立连接
        // 这样可以避免不必要的延迟，同时让 requestSync 的重试机制来处理连接建立
        
        // 更新注册状态
        await MainActor.run {
            peerManager.markAsRegistered(peerIDString)
        }
        
        print("[P2PNode] ✅ [retryPeerRegistration] 重试注册完成（不等待连接建立）: \(peerIDString.prefix(12))...")
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
        
        // 不等待，让 libp2p 在首次请求时自动建立连接
        // 这样可以避免不必要的延迟，同时让 requestSync 的重试机制来处理连接建立
        
        // 标记为已注册
        await MainActor.run {
            peerManager.markAsRegistered(peerID)
        }
        
        // 立即通知 SyncManager，让它在首次请求时触发连接建立
        await MainActor.run {
            self.onPeerDiscovered?(peerIDObj)
            // 通知后立即更新设备计数
            // SyncManager 的 onPeerDiscovered 回调会处理设备计数更新
        }
        
        print("[P2PNode] ✅ 对等点已注册（不等待连接建立）: \(peerID.prefix(12))... (\(parsedAddresses.count) 个地址)")
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
            
            // 只删除密钥相关文件，保留文件夹配置和其他数据
            let fileManager = FileManager.default
            
            // 需要保护的重要文件和目录（文件夹配置、冲突、日志、向量时钟等）
            let protectedItems: Set<String> = [
                "folders.json",
                "conflicts.json",
                "sync_logs.json",
                "peerid_password.txt",
                "vector_clocks"
            ]
            
            // 备份重要文件（不包括目录，因为目录会被保护不会被删除）
            var fileBackups: [String: Data] = [:]
            
            if fileManager.fileExists(atPath: folderSyncDir.path) {
                if let items = try? fileManager.contentsOfDirectory(at: folderSyncDir, includingPropertiesForKeys: [.isDirectoryKey]) {
                    for item in items {
                        let itemName = item.lastPathComponent
                        
                        // 只备份保护的文件（不包括目录，因为目录会被保护不会被删除）
                        if protectedItems.contains(itemName) {
                            var isDirectory: ObjCBool = false
                            if fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) {
                                if !isDirectory.boolValue {
                                    // 备份文件
                                    if let data = try? Data(contentsOf: item) {
                                        fileBackups[itemName] = data
                                        print("[P2PNode] 📦 已备份文件: \(itemName)")
                                    }
                                } else {
                                    // 目录会被保护，不会被删除，所以不需要备份
                                    print("[P2PNode] ℹ️ 目录 \(itemName) 受保护，无需备份")
                                }
                            }
                        }
                    }
                }
            }
            
            // 删除密钥相关文件（排除重要文件）
            // LibP2P 的密钥文件通常不是 JSON 格式，可能是二进制文件或其他格式
            do {
                if fileManager.fileExists(atPath: folderSyncDir.path) {
                    if let items = try? fileManager.contentsOfDirectory(at: folderSyncDir, includingPropertiesForKeys: [.isDirectoryKey]) {
                        for item in items {
                            let itemName = item.lastPathComponent
                            
                            // 跳过保护的文件和目录
                            if protectedItems.contains(itemName) {
                                continue
                            }
                            
                            // 检查是否是目录
                            var isDirectory: ObjCBool = false
                            if fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) {
                                if isDirectory.boolValue {
                                    // 跳过所有目录（受保护的目录已在上面被跳过）
                                    continue
                                }
                            }
                            
                            // 删除非保护的文件（可能是密钥文件）
                            // 密钥文件通常不是 JSON 格式
                            if !itemName.hasSuffix(".json") {
                                try? fileManager.removeItem(at: item)
                                print("[P2PNode] 🗑️ 已删除可能的密钥文件: \(itemName)")
                            }
                        }
                    }
                }
            } catch {
                print("[P2PNode] ⚠️ 删除密钥文件时出错: \(error.localizedDescription)")
            }
            
            // 确保目录存在
            try? fileManager.createDirectory(at: folderSyncDir, withIntermediateDirectories: true)
            
            // 恢复备份的文件
            for (fileName, data) in fileBackups {
                let fileURL = folderSyncDir.appendingPathComponent(fileName)
                try? data.write(to: fileURL, options: [.atomic])
                print("[P2PNode] ✅ 已恢复文件: \(fileName)")
            }
            
            // 注意：vector_clocks 目录在 protectedItems 中，不会被删除，因此不需要恢复逻辑
            
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
