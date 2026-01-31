import CryptoKit
import Foundation
import Network

/// Simple LAN discovery using UDP broadcast
public class LANDiscovery {
    private var listener: NWListener?
    private var broadcastConnection: NWConnection?
    private var broadcastTimer: Timer?
    private var discoveryRequestConnections: [NWConnection] = []  // 保持发现请求连接的强引用
    private let connectionsQueue = DispatchQueue(
        label: "com.foldersync.lanDiscovery.connections", attributes: .concurrent)  // 线程安全的连接数组访问
    private var isRunning = false
    private let servicePort: UInt16 = 8765  // Custom port for FolderSync discovery
    private let serviceName = "_foldersync._tcp"
    private let subscriberID = UUID()
    private var currentSyncIDs: [String] = []  // 当前设备的 syncID 列表
    private var myPeerID: String = ""  // Store peerID for re-broadcasting

    public var onPeerDiscovered: ((String, String, [String], [String]) -> Void)?  // (peerID, address, listenAddresses, syncIDs)

    public init() {}

    // MARK: - Shared UDP listener (process-wide)
    private static let sharedQueue = DispatchQueue(
        label: "com.foldersync.lanDiscovery.shared", qos: .userInitiated)
    private static var sharedListener: NWListener?
    private static var sharedHandlers: [UUID: (String, String) -> Void] = [:]  // id -> (message, remoteAddressDesc)

    private static func registerSharedHandler(id: UUID, handler: @escaping (String, String) -> Void)
    {
        sharedQueue.sync {
            sharedHandlers[id] = handler
        }
        ensureSharedListenerStarted()
    }

    /// 取消注册时不再关闭共享 listener，避免下一测试重新绑定端口时出现 Address already in use（同一进程内多测试顺序执行）
    private static func unregisterSharedHandler(id: UUID) {
        sharedQueue.sync {
            _ = sharedHandlers.removeValue(forKey: id)
        }
    }

    private static func ensureSharedListenerStarted() {
        sharedQueue.async {
            guard sharedListener == nil else { return }

            // 尝试在主端口或回退端口上启动监听器
            startSharedListenerWithFallback(basePort: servicePortStatic, attempt: 0)
        }
    }

    private static var actualListeningPort: UInt16 = servicePortStatic
    private static let maxPortAttempts = 5

    private static func startSharedListenerWithFallback(basePort: UInt16, attempt: Int) {
        guard sharedListener == nil else { return }
        guard attempt < maxPortAttempts else {
            AppLogger.syncPrint("[LANDiscovery] ❌ 无法在任何端口上启动监听器，已尝试 \(maxPortAttempts) 个端口")
            return
        }

        let portToTry = basePort + UInt16(attempt)

        // 使用正确的 UDP 参数配置以支持端口复用
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        // 配置 UDP 选项以支持地址复用
        if let options = parameters.defaultProtocolStack.internetProtocol
            as? NWProtocolIP.Options
        {
            // 设置 SO_REUSEADDR 等效选项
            options.version = .any
        }

        do {
            guard let port = NWEndpoint.Port(rawValue: portToTry) else {
                AppLogger.syncPrint("[LANDiscovery] ❌ 无效端口: \(portToTry)")
                startSharedListenerWithFallback(basePort: basePort, attempt: attempt + 1)
                return
            }

            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { connection in
                handleSharedIncomingConnection(connection)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    actualListeningPort = portToTry
                    AppLogger.syncPrint(
                        "[LANDiscovery] ✅ Listener ready on port \(portToTry)")
                case .failed(let error):
                    AppLogger.syncPrint(
                        "[LANDiscovery] ❌ Listener failed on port \(portToTry): \(error)")
                    // 如果失败，清理 sharedListener 并尝试下一个端口
                    sharedQueue.async {
                        sharedListener?.cancel()
                        sharedListener = nil
                        // 尝试下一个端口
                        startSharedListenerWithFallback(basePort: basePort, attempt: attempt + 1)
                    }
                case .waiting(let error):
                    AppLogger.syncPrint(
                        "[LANDiscovery] ⚠️ Listener waiting on port \(portToTry): \(error)")
                    // 等待状态通常意味着端口被占用，尝试下一个端口
                    if case .posix(let posixError) = error, posixError == .EADDRINUSE {
                        sharedQueue.async {
                            sharedListener?.cancel()
                            sharedListener = nil
                            startSharedListenerWithFallback(
                                basePort: basePort, attempt: attempt + 1)
                        }
                    }
                case .cancelled:
                    AppLogger.syncPrint("[LANDiscovery] ℹ️ Listener cancelled")
                default:
                    break
                }
            }
            listener.start(queue: sharedQueue)
            sharedListener = listener
        } catch {
            AppLogger.syncPrint(
                "[LANDiscovery] ❌ Failed to start listener on port \(portToTry): \(error)")
            // 尝试下一个端口
            startSharedListenerWithFallback(basePort: basePort, attempt: attempt + 1)
        }
    }

    // 由于 shared listener 是静态的，这里需要一个静态端口常量供静态方法使用
    private static let servicePortStatic: UInt16 = 8765

    private static func handleSharedIncomingConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                receiveSharedMessage(from: connection)
            case .failed(let error):
                AppLogger.syncPrint("[LANDiscovery] Connection failed: \(error)")
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: sharedQueue)
    }

    private static func receiveSharedMessage(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) {
            data, _, isComplete, error in
            if let error = error {
                if case .posix(let code) = error, code == .ECANCELED {
                    // ignore
                } else {
                    AppLogger.syncPrint("[LANDiscovery] ⚠️ 接收错误: \(error)")
                }
                connection.cancel()
                return
            }

            if let data = data, !data.isEmpty, let message = String(data: data, encoding: .utf8) {
                let address = connection.currentPath?.remoteEndpoint?.debugDescription ?? "unknown"
                sharedQueue.async {
                    for handler in sharedHandlers.values {
                        handler(message, address)
                    }
                }
            }

            if !isComplete {
                receiveSharedMessage(from: connection)
            } else {
                connection.cancel()
            }
        }
    }

    public func start(peerID: String, listenAddresses: [String] = [], syncIDs: [String] = []) {
        guard !isRunning else { return }
        isRunning = true
        currentSyncIDs = syncIDs
        myPeerID = peerID

        // 注册到进程级共享 UDP 监听器，避免同一进程内多实例抢占端口导致 EADDRINUSE
        LANDiscovery.registerSharedHandler(id: subscriberID) { [weak self] message, address in
            self?.handleIncomingMessage(message, from: address, myPeerID: peerID)
        }

        // Start broadcasting our presence
        startBroadcasting(peerID: peerID, listenAddresses: listenAddresses)
    }

    public func stop() {
        isRunning = false
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        LANDiscovery.unregisterSharedHandler(id: subscriberID)
        listener?.cancel()
        broadcastConnection?.cancel()

        // 线程安全地取消所有发现请求连接
        connectionsQueue.sync(flags: .barrier) {
            discoveryRequestConnections.forEach { $0.cancel() }
            discoveryRequestConnections.removeAll()
        }

        listener = nil
        broadcastConnection = nil
    }

    // MARK: - Helper Methods

    private func getSyncIDHash(_ syncID: String) -> String {
        let inputData = Data(syncID.utf8)
        let hashed = SHA256.hash(data: inputData)
        // Use first 8 bytes (16 hex chars)
        return hashed.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func handleIncomingMessage(_ message: String, from address: String, myPeerID: String) {
        guard isRunning else { return }

        // 检查是否是发现请求
        if message.contains("\"type\":\"discovery_request\"") {
            // 收到发现请求，立即广播自己的信息作为响应
            sendBroadcast(peerID: myPeerID, listenAddresses: currentListenAddresses)
            return
        }

        // 解析正常的发现消息 (returns hashes in syncIDHashes)
        if let peerInfo = parseDiscoveryMessage(message) {
            // Ignore our own broadcasts
            if peerInfo.peerID != myPeerID {
                // 安全匹配：只回调那些我们也有的 syncID (通过哈希匹配)
                // 收到的是对方的 syncID 哈希列表
                let remoteHashes = Set(peerInfo.syncIDHashes)

                // 计算本地 syncID 的哈希映射: Hash -> OriginalID
                var localHashMap: [String: String] = [:]
                for id in currentSyncIDs {
                    localHashMap[getSyncIDHash(id)] = id
                }

                // 找出交集 (Mutual SyncIDs)
                var matchedSyncIDs: [String] = []
                for hash in remoteHashes {
                    if let localID = localHashMap[hash] {
                        matchedSyncIDs.append(localID)
                    }
                }

                onPeerDiscovered?(peerInfo.peerID, address, peerInfo.addresses, matchedSyncIDs)
            }
        }
    }

    /// 线程安全地添加连接
    private func addConnection(_ connection: NWConnection) {
        connectionsQueue.async(flags: .barrier) { [weak self] in
            self?.discoveryRequestConnections.append(connection)
        }
    }

    /// 线程安全地移除连接
    private func removeConnection(_ connection: NWConnection) {
        connectionsQueue.async(flags: .barrier) { [weak self] in
            self?.discoveryRequestConnections.removeAll { $0 === connection }
        }
    }

    private func startListener(peerID: String) {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(
                using: parameters, on: NWEndpoint.Port(rawValue: servicePort)!)

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingConnection(connection, myPeerID: peerID)
            }

            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    AppLogger.syncPrint(
                        "[LANDiscovery] ✅ Listener ready on port \(self.servicePort)")
                    self.sendDiscoveryRequest()
                case .failed(let error):
                    AppLogger.syncPrint("[LANDiscovery] ❌ Listener failed: \(error)")
                    if self.isRunning {
                        AppLogger.syncPrint("[LANDiscovery] 🔄 尝试重新启动监听器...")
                        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0)
                        { [weak self] in
                            guard let self = self, self.isRunning else { return }
                            self.startListener(peerID: peerID)
                        }
                    }
                case .waiting(let error):
                    AppLogger.syncPrint("[LANDiscovery] ⚠️ Listener waiting: \(error)")
                case .cancelled:
                    AppLogger.syncPrint("[LANDiscovery] ℹ️ Listener cancelled")
                default:
                    break
                }
            }

            listener.start(queue: DispatchQueue.global(qos: .userInitiated))
            self.listener = listener
        } catch {
            AppLogger.syncPrint("[LANDiscovery] ❌ Failed to start listener: \(error)")
        }
    }

    func sendDiscoveryRequest() {
        let requestMessage = "{\"type\":\"discovery_request\",\"service\":\"foldersync\"}"
        guard let data = requestMessage.data(using: .utf8) else { return }

        let host = NWEndpoint.Host("255.255.255.255")
        let port = NWEndpoint.Port(rawValue: servicePort)!
        let endpoint = NWEndpoint.hostPort(host: host, port: port)

        let connection = NWConnection(to: endpoint, using: .udp)
        addConnection(connection)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else {
                connection.cancel()
                return
            }

            switch state {
            case .ready:
                connection.send(
                    content: data,
                    completion: .contentProcessed { [weak self] error in
                        connection.cancel()
                        self?.removeConnection(connection)
                        if let error = error {
                            AppLogger.syncPrint(
                                "[LANDiscovery] Discovery request send error: \(error)")
                        }
                    })
            case .failed(let error):
                AppLogger.syncPrint("[LANDiscovery] Discovery request connection failed: \(error)")
                connection.cancel()
                self.removeConnection(connection)
            case .cancelled:
                self.removeConnection(connection)
            default:
                break
            }
        }

        connection.start(queue: DispatchQueue.global(qos: .utility))

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10.0) { [weak self] in
            var shouldCancel = false
            self?.connectionsQueue.sync {
                shouldCancel =
                    self?.discoveryRequestConnections.contains { $0 === connection } ?? false
            }

            if shouldCancel {
                connection.cancel()
                self?.removeConnection(connection)
            }
        }
    }

    private func handleIncomingConnection(_ connection: NWConnection, myPeerID: String) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveMessage(from: connection, myPeerID: myPeerID)
            case .failed(let error):
                AppLogger.syncPrint("[LANDiscovery] Connection failed: \(error)")
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
    }

    private func receiveMessage(from connection: NWConnection, myPeerID: String) {
        guard isRunning else {
            connection.cancel()
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) {
            [weak self] data, _, isComplete, error in
            guard let self = self, self.isRunning else {
                connection.cancel()
                return
            }

            if let error = error {
                if case .posix(let code) = error, code == .ECANCELED {
                } else {
                    AppLogger.syncPrint("[LANDiscovery] ⚠️ 接收错误: \(error)")
                }
                connection.cancel()
                return
            }

            if let data = data, !data.isEmpty, let message = String(data: data, encoding: .utf8) {
                if message.contains("\"type\":\"discovery_request\"") {
                    self.sendBroadcast(
                        peerID: myPeerID, listenAddresses: self.currentListenAddresses)
                    if !isComplete {
                        self.receiveMessage(from: connection, myPeerID: myPeerID)
                    }
                    return
                }

                if let peerInfo = self.parseDiscoveryMessage(message) {
                    if peerInfo.peerID != myPeerID {
                        let address =
                            connection.currentPath?.remoteEndpoint?.debugDescription ?? "unknown"

                        let remoteHashes = Set(peerInfo.syncIDHashes)
                        var localHashMap: [String: String] = [:]
                        for id in self.currentSyncIDs {
                            localHashMap[self.getSyncIDHash(id)] = id
                        }
                        var matchedSyncIDs: [String] = []
                        for hash in remoteHashes {
                            if let localID = localHashMap[hash] {
                                matchedSyncIDs.append(localID)
                            }
                        }

                        if !peerInfo.peerID.isEmpty {
                            self.onPeerDiscovered?(
                                peerInfo.peerID, address, peerInfo.addresses, matchedSyncIDs)
                        }
                    }
                }
            }

            if !isComplete {
                self.receiveMessage(from: connection, myPeerID: myPeerID)
            }
        }
    }

    private var currentListenAddresses: [String] = []

    private func startBroadcasting(peerID: String, listenAddresses: [String]) {
        self.currentListenAddresses = listenAddresses

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.broadcastTimer?.invalidate()
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
                [weak self] _ in
                guard let self = self else { return }
                DispatchQueue.global(qos: .utility).async {
                    self.sendBroadcast(peerID: peerID, listenAddresses: self.currentListenAddresses)
                }
            }
            RunLoop.current.add(timer, forMode: .common)
            self.broadcastTimer = timer
        }

        sendBroadcast(peerID: peerID, listenAddresses: listenAddresses)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
            [weak self] in
            self?.sendDiscoveryRequest()
        }
    }

    public func updateListenAddresses(_ addresses: [String]) {
        self.currentListenAddresses = addresses
    }

    public func updateSyncIDs(_ syncIDs: [String]) {
        self.currentSyncIDs = syncIDs
        if isRunning && !myPeerID.isEmpty {
            DispatchQueue.global(qos: .utility).async {
                self.sendBroadcast(
                    peerID: self.myPeerID, listenAddresses: self.currentListenAddresses)
            }
        }
    }

    private func sendBroadcast(peerID: String, listenAddresses: [String]) {
        guard isRunning else { return }

        let validAddresses = listenAddresses.filter { addr in
            if let (_, port) = AddressConverter.extractIPPort(from: addr) {
                return port > 0
            }
            return false
        }

        let message = createDiscoveryMessage(
            peerID: peerID, listenAddresses: validAddresses, syncIDs: currentSyncIDs)
        guard let data = message.data(using: .utf8) else { return }

        let host = NWEndpoint.Host("255.255.255.255")
        let port = NWEndpoint.Port(rawValue: servicePort)!
        let endpoint = NWEndpoint.hostPort(host: host, port: port)

        let connection = NWConnection(to: endpoint, using: .udp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(
                    content: data,
                    completion: .contentProcessed { error in
                        connection.cancel()
                    })
            case .failed:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func createDiscoveryMessage(
        peerID: String, listenAddresses: [String] = [], syncIDs: [String] = []
    ) -> String {
        let validAddresses = listenAddresses.filter { addr in
            if addr.contains("/tcp/0") || addr.hasSuffix("/tcp/0") { return false }
            return AddressConverter.extractIPPort(from: addr) != nil
        }

        let limitedSyncIDs = Array(syncIDs.prefix(20))
        let syncIDHashes = limitedSyncIDs.map { getSyncIDHash($0) }

        let addressesJson = validAddresses.map { "\"\($0)\"" }.joined(separator: ",")
        let hashesJson = syncIDHashes.map { "\"\($0)\"" }.joined(separator: ",")

        return
            "{\"peerID\":\"\(peerID)\",\"service\":\"foldersync\",\"addresses\":[\(addressesJson)],\"syncIDHashes\":[\(hashesJson)]}"
    }

    private func parseDiscoveryMessage(_ message: String) -> (
        peerID: String, service: String, addresses: [String], syncIDHashes: [String]
    )? {
        guard let data = message.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let peerID = json["peerID"] as? String else { return nil }
        guard let service = json["service"] as? String, service == "foldersync" else { return nil }

        let addresses = (json["addresses"] as? [String]) ?? []
        let syncIDHashes = (json["syncIDHashes"] as? [String]) ?? []

        if peerID.isEmpty { return nil }
        let validAddresses = addresses.filter { addr in
            if let (_, port) = AddressConverter.extractIPPort(from: addr) {
                return port > 0
            }
            return false
        }

        return (
            peerID: peerID, service: service, addresses: validAddresses, syncIDHashes: syncIDHashes
        )
    }
}
