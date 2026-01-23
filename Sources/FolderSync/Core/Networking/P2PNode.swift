import LibP2P
import LibP2PMDNS

public class P2PNode {
    public var app: Application?
    
    public init() {}
    
    public var onPeerDiscovered: ((String) -> Void)?
    
    public func start() async throws {
        // Create the LibP2P application with an ephemeral Ed25519 peerID
        let app = try await Application.make(.development, peerID: .ephemeral(type: .Ed25519))
        self.app = app
        
        // Enable mDNS for automatic local network peer discovery
        app.discovery.use(.mdns)
        
        // Register for peer discovery events specifically from discovery services
        app.discovery.onPeerDiscovered(self) { [weak self] peerInfo in
            let peerID = peerInfo.peer.b58String
            print("Found peer: \(peerID)")
            self?.onPeerDiscovered?(peerID)
        }
        
        // Start the application (boots, configures, and starts servers)
        try await app.startup()
        
        print("P2P Node started with PeerID: \(app.peerID.b58String)")
        print("Listening on: \(app.listenAddresses.map { $0.description })")
    }
    
    public func announce(service: String) async throws {
        guard let app = app else { return }
        // Announce a service (like a sync group ID) on the network
        _ = try await app.discovery.announce(.service(service)).get()
        print("Announced service: \(service)")
    }
    
    public func stop() async throws {
        try await app?.asyncShutdown()
    }
    
    public var peerID: String? {
        app?.peerID.b58String
    }
    
    public var listenAddresses: [String] {
        app?.listenAddresses.map { $0.description } ?? []
    }
}
