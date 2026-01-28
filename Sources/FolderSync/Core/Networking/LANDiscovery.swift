import Foundation
import Network

/// Simple LAN discovery using UDP broadcast
public class LANDiscovery {
    private var listener: NWListener?
    private var broadcastConnection: NWConnection?
    private var broadcastTimer: Timer?
    private var discoveryRequestConnections: [NWConnection] = [] // 保持发现请求连接的强引用
    private let connectionsQueue = DispatchQueue(label: "com.foldersync.lanDiscovery.connections", attributes: .concurrent) // 线程安全的连接数组访问
    private var isRunning = false
    private let servicePort: UInt16 = 8765 // Custom port for FolderSync discovery
    private let serviceName = "_foldersync._tcp"
    private let subscriberID = UUID()
    
    public var onPeerDiscovered: ((String, String, [String]) -> Void)? // (peerID, address, listenAddresses)
    
    public init() {}

    // MARK: - Shared UDP listener (process-wide)
    private static let sharedQueue = DispatchQueue(label: "com.foldersync.lanDiscovery.shared", qos: .userInitiated)
    private static var sharedListener: NWListener?
    private static var sharedHandlers: [UUID: (String, String) -> Void] = [:] // id -> (message, remoteAddressDesc)

    private static func registerSharedHandler(id: UUID, handler: @escaping (String, String) -> Void) {
        sharedQueue.sync {
            sharedHandlers[id] = handler
        }
        ensureSharedListenerStarted()
    }

    private static func unregisterSharedHandler(id: UUID) {
        let shouldStop: Bool = sharedQueue.sync {
            sharedHandlers.removeValue(forKey: id)
            return sharedHandlers.isEmpty
        }
        if shouldStop {
            sharedQueue.async {
                sharedListener?.cancel()
                sharedListener = nil
            }
        }
    }

    private static func ensureSharedListenerStarted() {
        sharedQueue.async {
            guard sharedListener == nil else { return }

            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true

            do {
                let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: servicePortStatic)!)
                listener.newConnectionHandler = { connection in
                    handleSharedIncomingConnection(connection)
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        print("[LANDiscovery] ✅ Listener ready on port \(servicePortStatic)")
                    case .failed(let error):
                        print("[LANDiscovery] ❌ Listener failed: \(error)")
                    case .waiting(let error):
                        print("[LANDiscovery] ⚠️ Listener waiting: \(error)")
                    case .cancelled:
                        print("[LANDiscovery] ℹ️ Listener cancelled")
                    default:
                        break
                    }
                }
                listener.start(queue: sharedQueue)
                sharedListener = listener
            } catch {
                print("[LANDiscovery] ❌ Failed to start listener: \(error)")
            }
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
                print("[LANDiscovery] Connection failed: \(error)")
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: sharedQueue)
    }

    private static func receiveSharedMessage(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, isComplete, error in
            if let error = error {
                if case .posix(let code) = error, code == .ECANCELED {
                    // ignore
                } else {
                    print("[LANDiscovery] ⚠️ 接收错误: \(error)")
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
    
    public func start(peerID: String, listenAddresses: [String] = []) {
        guard !isRunning else { return }
        isRunning = true

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

    // MARK: - Shared listener message handling (per instance)
    private func handleIncomingMessage(_ message: String, from address: String, myPeerID: String) {
        guard isRunning else { return }

        // 检查是否是发现请求
        if message.contains("\"type\":\"discovery_request\"") {
            // 收到发现请求，立即广播自己的信息作为响应
            sendBroadcast(peerID: myPeerID, listenAddresses: currentListenAddresses)
            return
        }

        // 解析正常的发现消息
        if let peerInfo = parseDiscoveryMessage(message) {
            // Ignore our own broadcasts
            if peerInfo.peerID != myPeerID {
                // 每次收到广播都触发回调，确保 lastSeenTime 被更新
                onPeerDiscovered?(peerInfo.peerID, address, peerInfo.addresses)
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
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: servicePort)!)
            
            // 使用 UDP 的无连接接收方式
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingConnection(connection, myPeerID: peerID)
            }
            
            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    print("[LANDiscovery] ✅ Listener ready on port \(self.servicePort)")
                    // 监听器就绪后，立即发送一次广播请求，触发其他设备响应
                    self.sendDiscoveryRequest()
                case .failed(let error):
                    print("[LANDiscovery] ❌ Listener failed: \(error)")
                    // 监听器失败时，尝试重新启动
                    if self.isRunning {
                        print("[LANDiscovery] 🔄 尝试重新启动监听器...")
                        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) { [weak self] in
                            guard let self = self, self.isRunning else { return }
                            self.startListener(peerID: peerID)
                        }
                    }
                case .waiting(let error):
                    print("[LANDiscovery] ⚠️ Listener waiting: \(error)")
                case .cancelled:
                    print("[LANDiscovery] ℹ️ Listener cancelled")
                default:
                    break
                }
            }
            
            listener.start(queue: DispatchQueue.global(qos: .userInitiated))
            self.listener = listener
        } catch {
            print("[LANDiscovery] ❌ Failed to start listener: \(error)")
        }
    }
    
    /// 发送发现请求，让其他设备知道新设备上线并请求它们广播自己的信息
    func sendDiscoveryRequest() {
        let requestMessage = "{\"type\":\"discovery_request\",\"service\":\"foldersync\"}"
        guard let data = requestMessage.data(using: .utf8) else { return }
        
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        
        let host = NWEndpoint.Host("255.255.255.255")
        let port = NWEndpoint.Port(rawValue: servicePort)!
        let endpoint = NWEndpoint.hostPort(host: host, port: port)
        
        let connection = NWConnection(to: endpoint, using: parameters)
        
        // 线程安全地添加连接到数组中以保持强引用，防止被释放
        addConnection(connection)
        
        // 使用 weak self 避免循环引用
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else {
                // 如果 self 已被释放，取消连接
                connection.cancel()
                return
            }
            
            switch state {
            case .ready:
                // 检查连接是否仍然有效（未被取消）
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    // 无论成功或失败，都要清理连接
                    connection.cancel()
                    self?.removeConnection(connection)
                    
                    if let error = error {
                        print("[LANDiscovery] Discovery request send error: \(error)")
                    }
                    // 减少发现请求的日志输出
                })
            case .failed(let error):
                print("[LANDiscovery] Discovery request connection failed: \(error)")
                connection.cancel()
                // 连接失败后，从数组中移除
                self.removeConnection(connection)
            case .cancelled:
                // 连接被取消，从数组中移除
                self.removeConnection(connection)
            default:
                break
            }
        }
        
        connection.start(queue: DispatchQueue.global(qos: .utility))
        
        // 设置超时机制：如果连接在10秒内没有完成，自动取消并清理
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10.0) { [weak self] in
            // 检查连接是否仍在数组中（未完成）
            var shouldCancel = false
            self?.connectionsQueue.sync {
                shouldCancel = self?.discoveryRequestConnections.contains { $0 === connection } ?? false
            }
            
            if shouldCancel {
                print("[LANDiscovery] ⚠️ Discovery request timeout, cancelling connection")
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
                print("[LANDiscovery] Connection failed: \(error)")
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
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            guard let self = self, self.isRunning else {
                connection.cancel()
                return
            }
            
            if let error = error {
                // 某些错误是正常的（如连接关闭），不需要记录
                if case .posix(let code) = error, code == .ECANCELED {
                    // 正常取消，不需要日志
                } else {
                    print("[LANDiscovery] ⚠️ 接收错误: \(error)")
                }
                connection.cancel()
                return
            }
            
            if let data = data, !data.isEmpty {
                if let message = String(data: data, encoding: .utf8) {
                    // 检查是否是发现请求
                    if message.contains("\"type\":\"discovery_request\"") {
                        // 收到发现请求，立即广播自己的信息作为响应
                        // 减少日志输出
                        self.sendBroadcast(peerID: myPeerID, listenAddresses: self.currentListenAddresses)
                        // 继续接收
                        if !isComplete {
                            self.receiveMessage(from: connection, myPeerID: myPeerID)
                        }
                        return
                    }
                    
                    // 解析正常的发现消息
                    if let peerInfo = self.parseDiscoveryMessage(message) {
                        // Ignore our own broadcasts
                        if peerInfo.peerID != myPeerID {
                            let address = connection.currentPath?.remoteEndpoint?.debugDescription ?? "unknown"
                            
                            // 验证 PeerID
                            if peerInfo.peerID.isEmpty {
                                print("[LANDiscovery] ❌ 错误: 解析得到的 PeerID 为空，忽略此对等点")
                                return
                            }
                            
                            if peerInfo.peerID.count < 10 {
                                print("[LANDiscovery] ⚠️ 警告: 解析得到的 PeerID 似乎过短: \(peerInfo.peerID)")
                            }
                            
                            // 减少日志输出，只在首次发现或每100次输出一次
                            // 每次收到广播都触发回调，确保 lastSeenTime 被更新
                            self.onPeerDiscovered?(peerInfo.peerID, address, peerInfo.addresses)
                        }
                    } else {
                        // 减少解析失败的日志输出，只在真正有问题时输出
                        // print("[LANDiscovery] ⚠️ 无法解析发现消息: \(message.prefix(100))...")
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
        
        // 确保在主线程上创建 Timer，这样它会在主 RunLoop 上运行
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // 如果已有定时器，先停止它
            self.broadcastTimer?.invalidate()
            
            // Broadcast every 1 second
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                // 在后台线程发送广播，避免阻塞主线程
                DispatchQueue.global(qos: .utility).async {
                    self.sendBroadcast(peerID: peerID, listenAddresses: self.currentListenAddresses)
                }
            }
            RunLoop.current.add(timer, forMode: .common)
            self.broadcastTimer = timer
            
            // 减少启动日志输出
        }
        
        // Send initial broadcast immediately
        sendBroadcast(peerID: peerID, listenAddresses: listenAddresses)
        
        // 在启动后立即发送发现请求，主动寻找已有设备
        // 延迟一小段时间确保监听器已就绪
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sendDiscoveryRequest()
        }
    }
    
    public func updateListenAddresses(_ addresses: [String]) {
        self.currentListenAddresses = addresses
    }
    
    private func sendBroadcast(peerID: String, listenAddresses: [String]) {
        guard isRunning else {
            print("[LANDiscovery] ⚠️ 广播已停止，跳过发送")
            return
        }
        
        // 验证地址有效性
        let validAddresses = listenAddresses.filter { addr in
            if let (_, port) = AddressConverter.extractIPPort(from: addr) {
                return port > 0
            }
            return false
        }
        
        if validAddresses.isEmpty && !listenAddresses.isEmpty {
            print("[LANDiscovery] ⚠️ 警告: 没有有效地址可广播（所有地址端口为0或格式错误）")
            // 仍然发送广播，但地址列表为空，让接收方知道设备存在但地址无效
        }
        
        let message = createDiscoveryMessage(peerID: peerID, listenAddresses: validAddresses)
        guard let data = message.data(using: .utf8) else {
            print("[LANDiscovery] ⚠️ 无法创建广播消息数据")
            return
        }
        
        // 每100次广播输出一次详细日志，减少日志输出
        if Int.random(in: 0..<100) == 0 {
            print("[LANDiscovery] 📡 发送广播: peerID=\(peerID.prefix(12))..., 地址数=\(validAddresses.count)")
        }
        
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        
        // Create broadcast endpoint
        let host = NWEndpoint.Host("255.255.255.255")
        let port = NWEndpoint.Port(rawValue: servicePort)!
        let endpoint = NWEndpoint.hostPort(host: host, port: port)
        
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error = error {
                        print("[LANDiscovery] ⚠️ 广播发送错误: \(error)")
                    } else {
                        // 日志已在 sendBroadcast 开始处输出，这里不需要重复
                    }
                    connection.cancel()
                })
            case .failed(let error):
                print("[LANDiscovery] ⚠️ 广播连接失败: \(error)")
                connection.cancel()
            case .cancelled:
                // 正常取消，不需要日志
                break
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .utility))
    }
    
    private func createDiscoveryMessage(peerID: String, listenAddresses: [String] = []) -> String {
        // JSON format: {"peerID": "...", "service": "foldersync", "addresses": [...]}
        // 过滤掉端口为0的地址（0表示自动分配，不能用于连接）
        let validAddresses = listenAddresses.filter { addr in
            // 检查地址格式：/ip4/IP/tcp/PORT
            if addr.contains("/tcp/0") || addr.hasSuffix("/tcp/0") {
                // 减少过滤日志输出
                return false
            }
            // 使用 AddressConverter 验证地址有效性
            if AddressConverter.extractIPPort(from: addr) == nil {
                // 减少过滤日志输出
                return false
            }
            return true
        }
        
        if validAddresses.isEmpty && !listenAddresses.isEmpty {
            // 只在真正有问题时输出警告
            print("[LANDiscovery] ⚠️ 警告: 所有地址都被过滤，没有有效地址可广播")
        }
        
        let addressesJson = validAddresses.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"peerID\":\"\(peerID)\",\"service\":\"foldersync\",\"addresses\":[\(addressesJson)]}"
    }
    
    private func parseDiscoveryMessage(_ message: String) -> (peerID: String, service: String, addresses: [String])? {
        guard let data = message.data(using: .utf8) else {
            print("[LANDiscovery] ❌ 无法将消息转换为 UTF-8 数据")
            return nil
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[LANDiscovery] ❌ 无法解析 JSON: \(message.prefix(100))...")
            return nil
        }
        
        guard let peerID = json["peerID"] as? String else {
            print("[LANDiscovery] ❌ JSON 中缺少 'peerID' 字段")
            print("[LANDiscovery]   JSON 键: \(json.keys.joined(separator: ", "))")
            return nil
        }
        
        guard let service = json["service"] as? String, service == "foldersync" else {
            print("[LANDiscovery] ⚠️ 服务不匹配或缺失: \(json["service"] ?? "nil")")
            return nil
        }
        
        let addresses = (json["addresses"] as? [String]) ?? []
        
        // 验证解析结果
        if peerID.isEmpty {
            print("[LANDiscovery] ❌ 错误: 解析得到的 PeerID 为空")
            return nil
        }
        
        // 过滤掉端口为0或无效的地址
        let validAddresses = addresses.filter { addr in
            if let (_, port) = AddressConverter.extractIPPort(from: addr) {
                if port > 0 {
                    return true
                } else {
                    // 减少过滤日志输出
                    return false
                }
            } else {
                // 减少过滤日志输出
                return false
            }
        }
        
        // 减少解析成功的详细日志输出
        
        return (peerID: peerID, service: service, addresses: validAddresses)
    }
}
