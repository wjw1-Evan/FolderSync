import LibP2P
import LibP2PMDNS
import Foundation
import Darwin

public class P2PNode {
    public var app: Application?
    
    public init() {}
    
    public var onPeerDiscovered: ((PeerID) -> Void)?
    
    public func start() async throws {
        // Create the LibP2P application with an ephemeral Ed25519 peerID
        let app = try await Application.make(.development, peerID: .ephemeral(type: .Ed25519))
        self.app = app
        
        // Enable mDNS for automatic local network peer discovery if available/allowed
        let env = ProcessInfo.processInfo.environment
        let mdnsEnv = env["FOLDERSYNC_ENABLE_MDNS"]?.lowercased()
        let mdnsEnabledByEnv = (mdnsEnv == nil) || (mdnsEnv == "1") || (mdnsEnv == "true") || (mdnsEnv == "yes")

        if mdnsEnabledByEnv {
            if P2PNode.hasActiveIPv4Interface(named: "en0") {
                app.discovery.use(.mdns)
            } else {
                print("[P2PNode] Skipping mDNS: required interface 'en0' not available with IPv4")
            }
        } else {
            print("[P2PNode] mDNS disabled via FOLDERSYNC_ENABLE_MDNS=")
        }
        
        // Register for peer discovery events specifically from discovery services
        app.discovery.onPeerDiscovered(self) { [weak self] peerInfo in
            print("Found peer: \(peerInfo.peer.b58String)")
            self?.onPeerDiscovered?(peerInfo.peer)
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

// MARK: - Network Interface Helpers
extension P2PNode {
    /// Returns true if the given interface name (e.g., "en0") has a non-loopback IPv4 address.
    private static func hasActiveIPv4Interface(named name: String) -> Bool {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return false }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr?.pointee {
            defer { ptr = current.ifa_next }
            guard let ifaNameC = current.ifa_name else { continue }
            let ifaName = String(cString: ifaNameC)
            guard ifaName == name else { continue }
            let flags = Int32(current.ifa_flags)
            // Skip loopback and interfaces that are down
            guard (flags & IFF_LOOPBACK) == 0, (flags & IFF_UP) != 0 else { continue }
            if let addr = current.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) {
                return true
            }
        }
        return false
    }

    // Intentionally no broader fallback: the upstream mDNS provider currently assumes 'en0'.
}
