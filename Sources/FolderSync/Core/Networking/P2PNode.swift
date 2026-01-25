import Darwin
import Foundation
import Network

public class P2PNode {
    private var lanDiscovery: LANDiscovery?
    @MainActor public let peerManager: PeerManager // 统一的 Peer 管理器
    @MainActor public let registrationService: PeerRegistrationService // Peer 注册服务
    
    // 原生网络服务（替代 libp2p）
    public let nativeNetwork: NativeNetworkService
    
    // 本机 PeerID（持久化存储）
    private var myPeerID: PeerID?
    
    public var onPeerDiscovered: ((PeerID) -> Void)? // Peer 发现回调
    
    // 网络路径监控，用于检测 IP 地址变化
    private var pathMonitor: NWPathMonitor?
    private var pathMonitorQueue: DispatchQueue?
    private var lastKnownIP: String = ""

    public init() {
        // PeerManager 和 PeerRegistrationService 需要在 MainActor 上初始化
        self.peerManager = MainActor.assumeIsolated { PeerManager() }
        self.registrationService = MainActor.assumeIsolated { PeerRegistrationService() }
        
        // 初始化原生网络服务
        self.nativeNetwork = NativeNetworkService()
        
        // 将 registrationService 关联到 peerManager
        Task { @MainActor in
            self.peerManager.registrationService = self.registrationService
        }
    }
    
    /// 获取对等点的缓存地址
    func getCachedAddresses(for peer: PeerID) async -> [Multiaddr]? {
        return await MainActor.run {
            return peerManager.getAddresses(for: peer.b58String)
        }
    }
    
    /// 从持久化存储预注册 peer（原生实现，无需 libp2p）
    @MainActor
    private func preRegisterPersistedPeers() async {
        let peersToRegister = peerManager.getPeersForPreRegistration()
        
        guard !peersToRegister.isEmpty else {
            print("[P2PNode] ℹ️ 没有需要预注册的 peer")
            return
        }
        
        print("[P2PNode] 🔄 开始预注册 \(peersToRegister.count) 个持久化的 peer...")
        
        registrationService.registerPeers(peersToRegister)
        
        print("[P2PNode] ✅ 完成预注册 \(peersToRegister.count) 个 peer")
    }
    
    /// 重新触发对等点注册（用于 peerNotFound 错误后的重试）
    @MainActor
    func retryPeerRegistration(peer: PeerID) async {
        let peerIDString = peer.b58String
        print("[P2PNode] 🔄 [retryPeerRegistration] 开始重试注册: \(peerIDString.prefix(12))...")
        
        // 检查是否已经注册
        if registrationService.isRegistered(peerIDString) {
            print("[P2PNode] ✅ [retryPeerRegistration] Peer 已注册，无需重试: \(peerIDString.prefix(12))...")
            return
        }
        
        let addresses = peerManager.getAddresses(for: peerIDString)
        
        print("[P2PNode] 📍 [retryPeerRegistration] 获取到的地址数量: \(addresses.count)")
        if !addresses.isEmpty {
            for (idx, addr) in addresses.enumerated() {
                print("[P2PNode]   [\(idx + 1)] \(addr)")
            }
        }
        
        guard !addresses.isEmpty else {
            print("[P2PNode] ❌ [retryPeerRegistration] 重试注册失败: 对等点无可用地址: \(peerIDString.prefix(12))...")
            print("[P2PNode] 💡 [retryPeerRegistration] 提示: 对等点可能还未被发现或地址信息丢失")
            print("[P2PNode] 💡 [retryPeerRegistration] 建议: 等待 LAN Discovery 重新发现该对等点")
            return
        }
        
        guard registrationService.isReady else {
            print("[P2PNode] ❌ [retryPeerRegistration] 重试注册失败: registrationService 未就绪: \(peerIDString.prefix(12))...")
            print("[P2PNode] 💡 [retryPeerRegistration] 提示: 等待 P2P 节点完全启动")
            return
        }
        
        // 使用 registrationService 重试注册
        let registered = registrationService.retryRegistration(peerID: peer, addresses: addresses)
        if registered {
            print("[P2PNode] ✅ [retryPeerRegistration] 重试注册成功: \(peerIDString.prefix(12))... (\(addresses.count) 个地址)")
        } else {
            print("[P2PNode] ⚠️ [retryPeerRegistration] 重试注册失败（可能正在注册中）: \(peerIDString.prefix(12))...")
            // 检查注册状态
            let state = registrationService.getRegistrationState(peerIDString)
            print("[P2PNode] 📊 [retryPeerRegistration] 当前注册状态: \(state)")
        }
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
                await self.handleDiscoveredPeer(peerID: discoveredPeerID, discoveryAddress: address, listenAddresses: peerAddresses)
            }
        }
        discovery.start(peerID: peerID, listenAddresses: listenAddresses)
        self.lanDiscovery = discovery
    }
    
    /// 处理发现的 peer（新的统一入口）
    @MainActor
    private func handleDiscoveredPeer(peerID: String, discoveryAddress: String, listenAddresses: [String]) async {
        print("[P2PNode] 🔍 处理发现的 peer: \(peerID.prefix(12))...")
        
        // 解析 PeerID
        guard let peerIDObj = try? PeerID(cid: peerID) else {
            print("[P2PNode] ❌ 无法解析 PeerID: \(peerID.prefix(12))...")
            return
        }
        
        // 生成可连接地址
        let connectableStrs = Self.buildConnectableAddresses(listenAddresses: listenAddresses, discoveryAddress: discoveryAddress)
        print("[P2PNode] 📋 [handleDiscoveredPeer] 可连接地址 (\(connectableStrs.count) 个):")
        for (index, addr) in connectableStrs.enumerated() {
            if let (ip, port) = AddressConverter.extractIPPort(from: addr) {
                print("[P2PNode]   [\(index+1)] \(addr) -> IP=\(ip), 端口=\(port)")
            } else {
                print("[P2PNode]   [\(index+1)] \(addr) -> 无效")
            }
        }
        
        // 解析地址
        var parsedAddresses: [Multiaddr] = []
        for addrStr in connectableStrs {
            if let addr = try? Multiaddr(addrStr) {
                parsedAddresses.append(addr)
            } else {
                print("[P2PNode] ⚠️ 无法解析地址: \(addrStr)")
            }
        }
        
        guard !parsedAddresses.isEmpty else {
            print("[P2PNode] ⚠️ 无有效地址，跳过: \(peerID.prefix(12))...")
            print("[P2PNode]   原始监听地址: \(listenAddresses)")
            print("[P2PNode]   发现地址: \(discoveryAddress)")
            print("[P2PNode]   可连接地址: \(connectableStrs)")
            return
        }
        
        print("[P2PNode] ✅ [handleDiscoveredPeer] 成功解析 \(parsedAddresses.count) 个有效地址")
        
        // 添加到 PeerManager
        let peerInfo = peerManager.addOrUpdatePeer(peerIDObj, addresses: parsedAddresses)
        
        // 更新最后可见时间（收到广播表示设备在线）
        // 注意：每次收到广播都应该更新 lastSeenTime，即使地址没有变化
        peerManager.updateLastSeen(peerID)
        
        // 检查是否需要注册（地址变化或未注册）
        let existing = peerManager.getPeer(peerID)
        let addressesChanged = Set(parsedAddresses.map { $0.description }) != Set(existing?.addresses.map { $0.description } ?? [])
        let needsRegistration = !registrationService.isRegistered(peerID) || addressesChanged
        
        if needsRegistration {
            // 注册到 libp2p peer store
            let registered = registrationService.registerPeer(peerID: peerIDObj, addresses: parsedAddresses)
            if registered {
                print("[P2PNode] ✅ 已注册 peer: \(peerID.prefix(12))...")
                
                // 更新设备状态为在线
                peerManager.updateDeviceStatus(peerID, status: .online)
                
                // 通知 SyncManager
                self.onPeerDiscovered?(peerIDObj)
            } else {
                // 注册失败，检查原因
                let state = registrationService.getRegistrationState(peerID)
                print("[P2PNode] ⚠️ Peer 注册失败: \(peerID.prefix(12))..., 状态: \(state)")
                
                // 即使注册失败，也更新设备状态并通知（让后续重试机制处理）
                peerManager.updateDeviceStatus(peerID, status: .online)
                self.onPeerDiscovered?(peerIDObj)
            }
        } else {
            print("[P2PNode] ⏭️ Peer 已注册且地址未变化，跳过: \(peerID.prefix(12))...")
            
            // 关键：即使地址未变化，收到广播也应该更新 lastSeenTime
            // 这表示设备仍然在线，只是地址没有变化
            peerManager.updateLastSeen(peerID)
            
            // 更新设备状态为在线
            peerManager.updateDeviceStatus(peerID, status: .online)
            
            // 即使已注册，也通知 SyncManager（可能状态有变化）
            self.onPeerDiscovered?(peerIDObj)
        }
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
        return listenAddresses.compactMap { addr in
            // 跳过端口为0的地址（0表示自动分配，不能用于连接）
            if addr.contains("/tcp/0") || addr.hasSuffix("/tcp/0") {
                print("[P2PNode] ⚠️ 跳过端口为0的地址: \(addr)")
                return nil
            }
            if addr.contains("/ip4/0.0.0.0/") {
                return addr.replacingOccurrences(of: "/ip4/0.0.0.0/", with: "/ip4/\(discoveryIP)/")
            }
            return addr
        }
    }
    

    public func start() async throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folderSyncDir = appSupport.appendingPathComponent("FolderSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderSyncDir, withIntermediateDirectories: true)
        
        // 加载或生成 PeerID
        let peerIDFile = folderSyncDir.appendingPathComponent("peerid.txt")
        let password = KeychainManager.loadOrCreatePassword()
        
        var peerID: PeerID
        if let savedPeerID = PeerID.load(from: peerIDFile, password: password) {
            peerID = savedPeerID
            print("[P2PNode] ✅ 已加载现有 PeerID: \(peerID.b58String.prefix(12))...")
        } else {
            // 生成新的 PeerID
            peerID = PeerID.generate()
            try? peerID.save(to: peerIDFile, password: password)
            print("[P2PNode] ✅ 已生成新 PeerID: \(peerID.b58String.prefix(12))...")
        }
        
        self.myPeerID = peerID

        // 获取本机真实 IP 地址用于监听
        let localIP = getLocalIPAddress()
        lastKnownIP = localIP
        print("[P2PNode] 📍 检测到本机 IP 地址: \(localIP)")
        
        // 启动原生 TCP 服务器
        do {
            let nativePort = try nativeNetwork.startServer(port: 0)
            guard nativePort > 0 else {
                throw NSError(domain: "P2PNode", code: -1, userInfo: [NSLocalizedDescriptionKey: "TCP 服务器启动失败：无法获取有效端口"])
            }
            print("[P2PNode] ✅ 原生 TCP 服务器已启动，端口: \(nativePort)")
        } catch {
            print("[P2PNode] ⚠️ 原生 TCP 服务器启动失败: \(error)")
            throw error
        }

        // 启用 LAN discovery（UDP 广播）
        setupLANDiscovery(peerID: peerID.b58String, listenAddresses: [])
        
        // 启动网络路径监控，监听 IP 地址变化
        startNetworkPathMonitoring()

        // 等待节点初始化完成
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        // 从持久化存储预注册 peer
        await MainActor.run {
            Task {
                await self.preRegisterPersistedPeers()
            }
        }

        // 更新 LAN discovery 的监听地址
        var addresses: [String] = []
        
        // 添加原生 TCP 服务器的地址
        if let nativePort = nativeNetwork.serverPort, nativePort > 0 {
            let nativeAddress = "/ip4/\(localIP)/tcp/\(nativePort)"
            addresses.append(nativeAddress)
            print("[P2PNode] ✅ 已添加原生 TCP 服务器地址到广播: \(nativeAddress)")
            print("[P2PNode] 📋 地址详情: IP=\(localIP), 端口=\(nativePort), 格式验证: ✅")
            
            // 验证地址格式
            if let (extractedIP, extractedPort) = AddressConverter.extractIPPort(from: nativeAddress) {
                if extractedIP == localIP && extractedPort == nativePort {
                    print("[P2PNode] ✅ 地址格式验证通过: \(extractedIP):\(extractedPort)")
                } else {
                    print("[P2PNode] ⚠️ 警告: 地址格式验证失败: 期望 \(localIP):\(nativePort), 实际 \(extractedIP):\(extractedPort)")
                }
            } else {
                print("[P2PNode] ❌ 错误: 无法从广播地址中提取 IP:Port: \(nativeAddress)")
            }
        } else {
            print("[P2PNode] ⚠️ 原生 TCP 服务器端口无效或未启动，无法添加到广播")
            if let port = nativeNetwork.serverPort {
                print("[P2PNode]   当前端口值: \(port) (无效)")
            } else {
                print("[P2PNode]   当前端口值: nil (未启动)")
            }
        }
        
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
        print("[P2PNode] PeerID: \(peerID.b58String)")
        
        if let nativePort = nativeNetwork.serverPort, nativePort > 0 {
            print("[P2PNode] 监听地址: /ip4/\(localIP)/tcp/\(nativePort)")
        }
        print("[P2PNode] ✅ Ready for connections")
        
        if lanDiscovery != nil {
            print("[P2PNode] ✅ LAN Discovery 已启用 (UDP 广播端口: 8765)")
        } else {
            print("[P2PNode] ❌ LAN Discovery 未启用")
        }
        
        print("[P2PNode] ======================================\n")
    }
    
    /// 获取本机的局域网 IP 地址
    private func getLocalIPAddress() -> String {
        var address = "127.0.0.1" // 默认值
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return address }
        guard let firstAddr = ifaddr else { return address }
        
        defer { freeifaddrs(ifaddr) }
        
        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            
            // 检查 ifa_addr 是否为 null（某些接口可能没有地址）
            guard let ifaAddr = interface.ifa_addr else {
                continue
            }
            
            // 检查是否为 IPv4 地址
            let addrFamily = ifaAddr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                // 检查接口名称，排除回环接口
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("eth") || name.hasPrefix("wlan") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(ifaAddr,
                               socklen_t(ifaAddr.pointee.sa_len),
                               &hostname,
                               socklen_t(hostname.count),
                               nil,
                               socklen_t(0),
                               NI_NUMERICHOST)
                    address = String(cString: hostname)
                    
                    // 优先选择非 127.0.0.1 的地址
                    if address != "127.0.0.1" && !address.isEmpty {
                        break
                    }
                }
            }
        }
        
        return address
    }
    
    /// 启动网络路径监控，监听 IP 地址变化
    private func startNetworkPathMonitoring() {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.foldersync.networkPathMonitor")
        
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            // 检查网络是否可用
            guard path.status == .satisfied else {
                print("[P2PNode] ⚠️ 网络路径不可用")
                return
            }
            
            // 延迟一小段时间，确保网络接口已完全更新
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                
                // 获取新的 IP 地址
                let newIP = self.getLocalIPAddress()
                
                // 如果 IP 地址发生变化（排除初始状态和回环地址）
                if !self.lastKnownIP.isEmpty && newIP != self.lastKnownIP && newIP != "127.0.0.1" {
                    print("[P2PNode] 🔄 检测到 IP 地址变化: \(self.lastKnownIP) -> \(newIP)")
                    let oldIP = self.lastKnownIP
                    self.lastKnownIP = newIP
                    
                    // 更新监听地址和广播地址
                    Task { [weak self] in
                        await self?.updateListenAddressForIPChange(newIP: newIP, oldIP: oldIP)
                    }
                } else if self.lastKnownIP.isEmpty && newIP != "127.0.0.1" {
                    // 首次设置 IP（启动时）
                    self.lastKnownIP = newIP
                }
            }
        }
        
        monitor.start(queue: queue)
        self.pathMonitor = monitor
        self.pathMonitorQueue = queue
        print("[P2PNode] ✅ 网络路径监控已启动")
    }
    
    /// 停止网络路径监控
    private func stopNetworkPathMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
        pathMonitorQueue = nil
        print("[P2PNode] ✅ 网络路径监控已停止")
    }
    
    /// 当 IP 地址改变时，更新监听地址和广播地址
    private func updateListenAddressForIPChange(newIP: String, oldIP: String) async {
        print("[P2PNode] 🔄 开始更新监听地址以适应新的 IP: \(newIP)")
        
        // 获取当前原生 TCP 服务器的端口
        guard let currentPort = nativeNetwork.serverPort, currentPort > 0 else {
            print("[P2PNode] ⚠️ 当前没有有效的监听端口，无法更新")
            return
        }
        
        // 停止旧服务器
        nativeNetwork.stopServer()
        
        // 使用新 IP 重新启动服务器（保持相同端口）
        do {
            let newPort = try nativeNetwork.startServer(port: currentPort)
            guard newPort > 0 else {
                throw NSError(domain: "P2PNode", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务器启动失败：端口无效"])
            }
            print("[P2PNode] 🔌 使用新 IP 和端口重新监听: \(newIP):\(newPort)")
        } catch {
            print("[P2PNode] ⚠️ 重新启动服务器失败: \(error)")
            // 尝试使用自动分配的端口
            do {
                let newPort = try nativeNetwork.startServer(port: 0)
                guard newPort > 0 else {
                    throw NSError(domain: "P2PNode", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务器启动失败：无法获取有效端口"])
                }
                print("[P2PNode] 🔌 使用新 IP 和自动分配端口重新监听: \(newIP):\(newPort)")
            } catch {
                print("[P2PNode] ❌ 无法重新启动服务器: \(error)")
                return
            }
        }
        
        // 等待服务器启动
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        // 更新 LAN Discovery 的广播地址
        var newAddresses: [String] = []
        if let nativePort = nativeNetwork.serverPort, nativePort > 0 {
            let nativeAddress = "/ip4/\(newIP)/tcp/\(nativePort)"
            newAddresses.append(nativeAddress)
            print("[P2PNode] ✅ 已更新广播地址: \(nativeAddress)")
            print("[P2PNode] 📋 地址详情: IP=\(newIP), 端口=\(nativePort)")
            
            // 验证地址格式
            if let (extractedIP, extractedPort) = AddressConverter.extractIPPort(from: nativeAddress) {
                if extractedIP == newIP && extractedPort == nativePort {
                    print("[P2PNode] ✅ 地址格式验证通过: \(extractedIP):\(extractedPort)")
                } else {
                    print("[P2PNode] ⚠️ 警告: 地址格式验证失败")
                }
            }
        } else {
            print("[P2PNode] ⚠️ 原生 TCP 服务器端口无效或未启动，无法更新广播地址")
        }
        
        lanDiscovery?.updateListenAddresses(newAddresses)
        print("[P2PNode] ✅ 已更新监听和广播地址: \(newAddresses)")
        
        // 立即发送一次广播，通知其他设备 IP 地址已改变
        lanDiscovery?.sendDiscoveryRequest()
        print("[P2PNode] 📡 已发送广播通知 IP 地址变化")
    }

    public func announce(service: String) async throws {
        // 原生实现：通过 LAN Discovery 广播服务
        print("[P2PNode] 📡 广播服务: \(service)")
        lanDiscovery?.sendDiscoveryRequest()
    }

    public func stop() async throws {
        // 停止网络路径监控
        stopNetworkPathMonitoring()
        
        // 保存所有 peer 到持久化存储
        await peerManager.saveAllPeers()
        
        // 停止原生 TCP 服务器
        nativeNetwork.stopServer()
        
        lanDiscovery?.stop()
    }

    public var peerID: String? {
        return myPeerID?.b58String
    }

    public var listenAddresses: [String] {
        guard let nativePort = nativeNetwork.serverPort, nativePort > 0 else {
            print("[P2PNode] ⚠️ 无法获取有效的监听端口")
            return []
        }
        let localIP = getLocalIPAddress()
        return ["/ip4/\(localIP)/tcp/\(nativePort)"]
    }
}
