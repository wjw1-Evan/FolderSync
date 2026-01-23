import Darwin
import Foundation
import LibP2P
import LibP2PMDNS
import NIOCore

public class P2PNode {
    public var app: Application?

    public init() {}
    
    public var onPeerDiscovered: ((PeerID) -> Void)?
    public func start() async throws {
        // Create the LibP2P application with an ephemeral Ed25519 peerID
        let app = try await Application.make(.development, peerID: .ephemeral(type: .Ed25519))
        self.app = app

        // Explicitly configure TCP to listen on all interfaces
        // Using port 0 allows the OS to assign any available port
        app.listen(.tcp(host: "0.0.0.0", port: 0))

        // Enable mDNS for automatic local network peer discovery
        let env = ProcessInfo.processInfo.environment
        let mdnsEnv = env["FOLDERSYNC_ENABLE_MDNS"]?.lowercased()
        let mdnsEnabledByEnv = (mdnsEnv == nil) || (mdnsEnv == "1") || (mdnsEnv == "true") || (mdnsEnv == "yes")

        if mdnsEnabledByEnv {
            if P2PNode.isLibrarySafeInterfaceAvailable() {
                print("[P2PNode] Detected safe en0 interface, enabling mDNS")
                app.discovery.use(.mdns)
            } else {
                print("[P2PNode] Warning: Current network interface (en1 or incomplete en0) is incompatible with mDNS library. Skipping mDNS to prevent crash.")
                print("[P2PNode] You can still sync by manually connecting to Peer IDs if implemented.")
            }
        }

        // Register for peer discovery events
        app.discovery.onPeerDiscovered(self) { [weak self] (peerInfo:PeerInfo) in
            print("Found peer: \(peerInfo.peer.b58String)")
            self?.onPeerDiscovered?(peerInfo.peer)
        }

        // Start the application in a background Task so it doesn't block the caller
        Task {
            do {
                try await app.startup()
            } catch {
                print("[P2PNode] Critical failure during startup: \(error)")
            }
        }
        
        // Give the node a moment to initialize the server and update listenAddresses
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        
        print("P2P Node initializing with PeerID: \(app.peerID.b58String)")
        print("Ready for connections. Listening on: \(app.listenAddresses)")
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
    /// Checks if 'en0' is available and has both IPv4 and IPv6 addresses.
    /// This is the only configuration where the current LibP2PMDNS library is 
    /// guaranteed not to crash during its default initialization.
    private static func isLibrarySafeInterfaceAvailable() -> Bool {
        let devices = try? NIOCore.System.enumerateDevices()
        let en0Devices = devices?.filter { $0.name == "en0" } ?? []
        
        let hasV4 = en0Devices.contains { $0.address?.protocol == .inet }
        let hasV6 = en0Devices.contains { $0.address?.protocol == .inet6 }
        
        return hasV4 && hasV6
    }
}
