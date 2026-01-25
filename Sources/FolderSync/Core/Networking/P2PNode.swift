import Darwin
import Foundation
import LibP2P
import LibP2PKadDHT
import NIOCore
import Network

public class P2PNode {
    public var app: Application?
    private var lanDiscovery: LANDiscovery?
    @MainActor public let peerManager: PeerManager // 统一的 Peer 管理器
    @MainActor public let registrationService: PeerRegistrationService // Peer 注册服务
    
    public var onPeerDiscovered: ((PeerID) -> Void)? // Peer 发现回调
    
    // 网络路径监控，用于检测 IP 地址变化
    private var pathMonitor: NWPathMonitor?
    private var pathMonitorQueue: DispatchQueue?
    private var lastKnownIP: String = ""

    public init() {
        // PeerManager 和 PeerRegistrationService 需要在 MainActor 上初始化
        self.peerManager = MainActor.assumeIsolated { PeerManager() }
        self.registrationService = MainActor.assumeIsolated { PeerRegistrationService() }
        
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
    
    /// 从持久化存储预注册 peer 到 libp2p peer store
    @MainActor
    private func preRegisterPersistedPeers() async {
        guard registrationService.isReady else {
            print("[P2PNode] ⚠️ 无法预注册 peer：registrationService 未就绪")
            return
        }
        
        let peersToRegister = peerManager.getPeersForPreRegistration()
        
        guard !peersToRegister.isEmpty else {
            print("[P2PNode] ℹ️ 没有需要预注册的 peer")
            return
        }
        
        print("[P2PNode] 🔄 开始预注册 \(peersToRegister.count) 个持久化的 peer 到 libp2p peer store...")
        
        registrationService.registerPeers(peersToRegister)
        
        print("[P2PNode] ✅ 完成预注册 \(peersToRegister.count) 个 peer")
    }
    
    /// 重新触发对等点注册（用于 peerNotFound 错误后的重试）
    @MainActor
    func retryPeerRegistration(peer: PeerID) async {
        let peerIDString = peer.b58String
        print("[P2PNode] 🔄 [retryPeerRegistration] 开始重试注册: \(peerIDString.prefix(12))...")
        
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
            return
        }
        
        guard registrationService.isReady else {
            print("[P2PNode] ❌ [retryPeerRegistration] 重试注册失败: registrationService 未就绪: \(peerIDString.prefix(12))...")
            return
        }
        
        // 使用 registrationService 重试注册
        let registered = registrationService.retryRegistration(peerID: peer, addresses: addresses)
        if registered {
            print("[P2PNode] ✅ [retryPeerRegistration] 重试注册成功: \(peerIDString.prefix(12))... (\(addresses.count) 个地址)")
        } else {
            print("[P2PNode] ⚠️ [retryPeerRegistration] 重试注册失败（可能正在注册中）: \(peerIDString.prefix(12))...")
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
        
        // 解析地址
        var parsedAddresses: [Multiaddr] = []
        for addrStr in connectableStrs {
            if let addr = try? Multiaddr(addrStr) {
                parsedAddresses.append(addr)
            }
        }
        
        guard !parsedAddresses.isEmpty else {
            print("[P2PNode] ⚠️ 无有效地址，跳过: \(peerID.prefix(12))...")
            return
        }
        
        // 添加到 PeerManager
        let peerInfo = peerManager.addOrUpdatePeer(peerIDObj, addresses: parsedAddresses)
        
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
            }
        } else {
            print("[P2PNode] ⏭️ Peer 已注册且地址未变化，跳过: \(peerID.prefix(12))...")
            
            // 更新设备状态为在线
            peerManager.updateDeviceStatus(peerID, status: .online)
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
        return listenAddresses.map { addr in
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
                            do {
                                try fileManager.removeItem(at: item)
                                print("[P2PNode] 🗑️ 已删除可能的密钥文件: \(itemName)")
                            } catch {
                                print("[P2PNode] ⚠️ 删除密钥文件时出错: \(error.localizedDescription)")
                            }
                        }
                    }
                }
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

        // 获取本机真实 IP 地址用于监听
        let localIP = getLocalIPAddress()
        lastKnownIP = localIP
        print("[P2PNode] 📍 检测到本机 IP 地址: \(localIP)")
        
        // 使用真实 IP 地址监听，而不是 0.0.0.0
        // 使用 port 0 让系统自动分配可用端口
        app.listen(.tcp(host: localIP, port: 0))
        print("[P2PNode] 🔌 正在监听: \(localIP):0 (端口将由系统分配)")

        // 启用 LAN discovery（UDP 广播）
        setupLANDiscovery(peerID: app.peerID.b58String, listenAddresses: [])
        
        // 启动网络路径监控，监听 IP 地址变化
        startNetworkPathMonitoring()
        
        // 注册 libp2p 的 peer 发现回调
        let discoveryHandler: (LibP2P.PeerInfo) -> Void = { [weak self] (peerInfo: LibP2P.PeerInfo) in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // 添加到 PeerManager
                self.peerManager.addOrUpdatePeer(peerInfo.peer, addresses: peerInfo.addresses)
                // 更新设备状态为在线
                self.peerManager.updateDeviceStatus(peerInfo.peer.b58String, status: .online)
                // 通知 SyncManager
                self.onPeerDiscovered?(peerInfo.peer)
            }
        }
        
        app.discovery.onPeerDiscovered(self, closure: discoveryHandler)
        
        // 设置 registrationService 的 discovery handler
        await MainActor.run {
            registrationService.setDiscoveryHandler(discoveryHandler)
        }

        // 启动应用
        do {
            try await app.startup()
        } catch {
            print("[P2PNode] ❌ 启动失败: \(error)")
            throw error
        }

        // 等待节点初始化完成
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        // 从持久化存储预注册 peer 到 libp2p peer store
        await MainActor.run {
            Task {
                await self.preRegisterPersistedPeers()
            }
        }

        // 更新 LAN discovery 的监听地址
        // 将 0.0.0.0 替换为真实 IP 地址，确保广播的地址可以被其他设备连接
        // 重用之前获取的 localIP
        let addresses = app.listenAddresses.map { addr in
            let addrStr = addr.description
            // 将 /ip4/0.0.0.0/ 替换为真实 IP
            return addrStr.replacingOccurrences(of: "/ip4/0.0.0.0/", with: "/ip4/\(localIP)/")
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
        print("[P2PNode] PeerID: \(app.peerID.b58String)")
        print("[P2PNode] 监听地址数量: \(app.listenAddresses.count)")
        
        if app.listenAddresses.isEmpty {
            print("[P2PNode] ⚠️ 警告: 未检测到监听地址")
        } else {
            // 获取本机真实 IP 地址
            let localIP = getLocalIPAddress()
            
            for (index, addr) in app.listenAddresses.enumerated() {
                // 将 0.0.0.0 替换为真实 IP 地址以便显示
                let addrStr = addr.description
                let displayAddr = addrStr.replacingOccurrences(of: "/ip4/0.0.0.0/", with: "/ip4/\(localIP)/")
                print("[P2PNode]   [\(index + 1)] \(displayAddr)")
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
        guard let app = app else { return }
        
        print("[P2PNode] 🔄 开始更新监听地址以适应新的 IP: \(newIP)")
        
        // 获取当前的监听地址（包含端口信息）
        let currentAddresses = app.listenAddresses
        guard !currentAddresses.isEmpty else {
            print("[P2PNode] ⚠️ 当前没有监听地址，无法更新")
            return
        }
        
        // 提取端口号（从第一个地址中）
        var port: UInt16 = 0
        for addr in currentAddresses {
            let addrStr = addr.description
            // 解析 multiaddr 格式，例如 /ip4/192.168.1.100/tcp/51027
            if let tcpRange = addrStr.range(of: "/tcp/") {
                let portStr = String(addrStr[tcpRange.upperBound...])
                if let portNum = UInt16(portStr) {
                    port = portNum
                    break
                }
            }
        }
        
        if port == 0 {
            print("[P2PNode] ⚠️ 无法从当前地址提取端口号，尝试使用新 IP 重新监听")
            // 如果无法提取端口，使用新 IP 重新监听（系统会分配新端口）
            app.listen(.tcp(host: newIP, port: 0))
            print("[P2PNode] 🔌 已使用新 IP 重新监听: \(newIP):0")
            
            // 等待系统分配端口
            try? await Task.sleep(nanoseconds: 500_000_000)
        } else {
            // 使用相同的端口，但使用新的 IP 地址重新监听
            print("[P2PNode] 🔌 使用新 IP 和相同端口重新监听: \(newIP):\(port)")
            app.listen(.tcp(host: newIP, port: Int(port)))
            
            // 等待监听启动
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        
        // 获取更新后的监听地址
        let updatedAddresses = app.listenAddresses.map { $0.description }
        
        // 更新 LAN Discovery 的广播地址，确保使用新 IP
        let newAddresses = updatedAddresses.map { addr in
            let addrStr = addr
            // 将旧 IP 或 0.0.0.0 替换为新 IP
            var newAddr = addrStr
            // 替换 /ip4/0.0.0.0/ 或 /ip4/旧IP/
            if newAddr.contains("/ip4/\(oldIP)/") {
                // 替换旧 IP
                newAddr = newAddr.replacingOccurrences(of: "/ip4/\(oldIP)/", with: "/ip4/\(newIP)/")
            } else if newAddr.contains("/ip4/0.0.0.0/") {
                // 替换 0.0.0.0
                newAddr = newAddr.replacingOccurrences(of: "/ip4/0.0.0.0/", with: "/ip4/\(newIP)/")
            } else {
                // 如果地址中没有旧 IP 或 0.0.0.0，尝试查找并替换任何 IP
                // 使用简单的字符串查找和替换
                if let ipRange = newAddr.range(of: "/ip4/") {
                    let afterIPStart = ipRange.upperBound
                    // 在原始字符串的剩余部分中查找下一个斜杠
                    // 使用 range(of:) 在子字符串中查找，然后转换为原始字符串的索引
                    let remainingString = String(newAddr[afterIPStart...])
                    if let slashIndex = remainingString.firstIndex(of: "/") {
                        // 计算在原始字符串中的位置
                        let slashOffset = remainingString.distance(from: remainingString.startIndex, to: slashIndex)
                        let nextSlashInOriginal = newAddr.index(afterIPStart, offsetBy: slashOffset)
                        let oldIPPart = String(newAddr[ipRange.lowerBound..<newAddr.index(after: nextSlashInOriginal)])
                        newAddr = newAddr.replacingOccurrences(of: oldIPPart, with: "/ip4/\(newIP)/")
                    }
                }
            }
            return newAddr
        }
        
        lanDiscovery?.updateListenAddresses(newAddresses)
        print("[P2PNode] ✅ 已更新监听和广播地址: \(newAddresses)")
        
        // 立即发送一次广播，通知其他设备 IP 地址已改变
        lanDiscovery?.sendDiscoveryRequest()
        print("[P2PNode] 📡 已发送广播通知 IP 地址变化")
    }

    public func announce(service: String) async throws {
        guard let app = app else { return }
        // Announce a service (like a sync group ID) on the network
        _ = try await app.discovery.announce(.service(service)).get()
        print("Announced service: \(service)")
    }

    public func stop() async throws {
        // 停止网络路径监控
        stopNetworkPathMonitoring()
        
        // 保存所有 peer 到持久化存储
        await MainActor.run {
            Task {
                await peerManager.saveAllPeers()
            }
        }
        
        lanDiscovery?.stop()
        try await app?.asyncShutdown()
    }

    public var peerID: String? {
        app?.peerID.b58String
    }

    public var listenAddresses: [String] {
        guard let app = app else { return [] }
        let localIP = getLocalIPAddress()
        // 返回的地址中将 0.0.0.0 替换为真实 IP，确保外部访问时使用真实地址
        return app.listenAddresses.map { addr in
            let addrStr = addr.description
            return addrStr.replacingOccurrences(of: "/ip4/0.0.0.0/", with: "/ip4/\(localIP)/")
        }
    }
}
