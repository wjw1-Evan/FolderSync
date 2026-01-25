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
    
    public var onPeerDiscovered: ((String, String, [String]) -> Void)? // (peerID, address, listenAddresses)
    
    public init() {}
    
    public func start(peerID: String, listenAddresses: [String] = []) {
        guard !isRunning else { return }
        isRunning = true
        
        // Start listening for broadcasts
        startListener(peerID: peerID)
        
        // Start broadcasting our presence
        startBroadcasting(peerID: peerID, listenAddresses: listenAddresses)
    }
    
    public func stop() {
        isRunning = false
        broadcastTimer?.invalidate()
        broadcastTimer = nil
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
                switch state {
                case .ready:
                    print("[LANDiscovery] ✅ Listener ready on port \(self?.servicePort ?? 0)")
                    // 监听器就绪后，立即发送一次广播请求，触发其他设备响应
                    if let self = self {
                        // 发送一个特殊的"发现请求"广播，让其他设备知道新设备上线
                        self.sendDiscoveryRequest()
                    }
                case .failed(let error):
                    print("[LANDiscovery] ❌ Listener failed: \(error)")
                case .waiting(let error):
                    print("[LANDiscovery] ⚠️ Listener waiting: \(error)")
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
                    } else {
                        print("[LANDiscovery] 📡 已发送发现请求，等待其他设备响应...")
                    }
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            if let error = error {
                print("[LANDiscovery] Receive error: \(error)")
                connection.cancel()
                return
            }
            
            if let data = data, !data.isEmpty {
                if let message = String(data: data, encoding: .utf8) {
                    // 检查是否是发现请求
                    if message.contains("\"type\":\"discovery_request\"") {
                        // 收到发现请求，立即广播自己的信息作为响应
                        print("[LANDiscovery] 📥 收到发现请求，立即响应...")
                        self?.sendBroadcast(peerID: myPeerID, listenAddresses: self?.currentListenAddresses ?? [])
                        // 继续接收
                        if !isComplete {
                            self?.receiveMessage(from: connection, myPeerID: myPeerID)
                        }
                        return
                    }
                    
                    // 解析正常的发现消息
                    if let peerInfo = self?.parseDiscoveryMessage(message) {
                        // Ignore our own broadcasts
                        if peerInfo.peerID != myPeerID {
                            let address = connection.currentPath?.remoteEndpoint?.debugDescription ?? "unknown"
                            print("[LANDiscovery] ✅ Discovered peer:")
                            print("[LANDiscovery]   - PeerID (完整): \(peerInfo.peerID)")
                            print("[LANDiscovery]   - PeerID (长度): \(peerInfo.peerID.count) 字符")
                            print("[LANDiscovery]   - 发现地址: \(address)")
                            print("[LANDiscovery]   - 监听地址数量: \(peerInfo.addresses.count)")
                            
                            // 验证 PeerID
                            if peerInfo.peerID.isEmpty {
                                print("[LANDiscovery] ❌ 错误: 解析得到的 PeerID 为空，忽略此对等点")
                                return
                            }
                            
                            if peerInfo.peerID.count < 10 {
                                print("[LANDiscovery] ⚠️ 警告: 解析得到的 PeerID 似乎过短: \(peerInfo.peerID)")
                            }
                            
                            self?.onPeerDiscovered?(peerInfo.peerID, address, peerInfo.addresses)
                        } else {
                            print("[LANDiscovery] ℹ️ 忽略自己的广播消息")
                        }
                    } else {
                        print("[LANDiscovery] ⚠️ 无法解析发现消息: \(message.prefix(100))...")
                    }
                }
            }
            
            if !isComplete {
                self?.receiveMessage(from: connection, myPeerID: myPeerID)
            }
        }
    }
    
    private var currentListenAddresses: [String] = []
    
    private func startBroadcasting(peerID: String, listenAddresses: [String]) {
        self.currentListenAddresses = listenAddresses
        // Broadcast every 5 seconds
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.sendBroadcast(peerID: peerID, listenAddresses: self.currentListenAddresses)
        }
        RunLoop.current.add(timer, forMode: .common)
        self.broadcastTimer = timer
        
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
        let message = createDiscoveryMessage(peerID: peerID, listenAddresses: listenAddresses)
        guard let data = message.data(using: .utf8) else { return }
        
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
                        print("[LANDiscovery] Broadcast send error: \(error)")
                    }
                    connection.cancel()
                })
            case .failed(let error):
                print("[LANDiscovery] Broadcast connection failed: \(error)")
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .utility))
    }
    
    private func createDiscoveryMessage(peerID: String, listenAddresses: [String] = []) -> String {
        // JSON format: {"peerID": "...", "service": "foldersync", "addresses": [...]}
        let addressesJson = listenAddresses.map { "\"\($0)\"" }.joined(separator: ",")
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
        
        print("[LANDiscovery] 📋 解析发现消息成功:")
        print("[LANDiscovery]   - PeerID: \(peerID) (长度: \(peerID.count))")
        print("[LANDiscovery]   - Service: \(service)")
        print("[LANDiscovery]   - Addresses: \(addresses.count) 个")
        
        return (peerID: peerID, service: service, addresses: addresses)
    }
}
