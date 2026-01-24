import Foundation
import Network
import NIOCore

/// Simple LAN discovery using UDP broadcast
public class LANDiscovery {
    private var listener: NWListener?
    private var broadcastConnection: NWConnection?
    private var broadcastTimer: Timer?
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
        listener = nil
        broadcastConnection = nil
    }
    
    private func startListener(peerID: String) {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        
        do {
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: servicePort)!)
            
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingConnection(connection, myPeerID: peerID)
            }
            
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[LANDiscovery] Listener ready on port \(self.servicePort)")
                case .failed(let error):
                    print("[LANDiscovery] Listener failed: \(error)")
                default:
                    break
                }
            }
            
            listener.start(queue: DispatchQueue.global(qos: .userInitiated))
            self.listener = listener
        } catch {
            print("[LANDiscovery] Failed to start listener: \(error)")
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
                if let message = String(data: data, encoding: .utf8),
                   let peerInfo = self?.parseDiscoveryMessage(message) {
                    // Ignore our own broadcasts
                    if peerInfo.peerID != myPeerID {
                        let address = connection.currentPath?.remoteEndpoint?.debugDescription ?? "unknown"
                        print("[LANDiscovery] Discovered peer: \(peerInfo.peerID) at \(address) with addresses: \(peerInfo.addresses)")
                        self?.onPeerDiscovered?(peerInfo.peerID, address, peerInfo.addresses)
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
        
        // Send initial broadcast
        sendBroadcast(peerID: peerID, listenAddresses: listenAddresses)
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
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peerID = json["peerID"] as? String,
              let service = json["service"] as? String,
              service == "foldersync" else {
            return nil
        }
        let addresses = (json["addresses"] as? [String]) ?? []
        return (peerID: peerID, service: service, addresses: addresses)
    }
}
