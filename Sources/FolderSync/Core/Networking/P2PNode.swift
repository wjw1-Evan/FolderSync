import Darwin
import Foundation
import LibP2P
import LibP2PMDNS
import NIOCore

public class P2PNode {
    public var app: Application?

    public init() {}

    /// Determine whether mDNS is allowed based on the provided environment.
    /// Default is allowed unless explicitly turned off.
    static func isMdnsAllowed(env: [String: String]) -> Bool {
        let mdnsEnv = env["FOLDERSYNC_ENABLE_MDNS"]?.lowercased()
        switch mdnsEnv {
        case "0", "false", "no", "off":
            return false
        default:
            return true
        }
    }

    /// Check whether the given address matches any enumerated network device.
    /// LibP2PMDNS will crash if it cannot resolve the address back to an interface,
    /// so we preflight this before calling into the library.
    private func hasMatchingInterface(for address: SocketAddress) -> Bool {
        guard let devices = try? NIOCore.System.enumerateDevices() else { return false }
        return devices.contains(where: { $0.address == address })
    }

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
        let mdnsAllowed = Self.isMdnsAllowed(env: env)

        if mdnsAllowed {
            let devices = (try? NIOCore.System.enumerateDevices()) ?? []
            // Prefer IPv4 non-loopback, then IPv6 non-loopback
            let candidates: [(NIONetworkDevice, SocketAddress)] = devices.compactMap { device in
                guard let address = device.address else { return nil }
                guard device.name != "lo0" else { return nil }
                return (device, address)
            }.sorted {
                (lhs: (NIONetworkDevice, SocketAddress), rhs: (NIONetworkDevice, SocketAddress))
                    -> Bool in
                // IPv4 before IPv6
                if lhs.1.protocol == .inet && rhs.1.protocol == .inet6 { return true }
                if lhs.1.protocol == .inet6 && rhs.1.protocol == .inet { return false }
                return lhs.0.name < rhs.0.name
            }

            var bound = false
            for (device, address) in candidates {
                // LibP2PMDNS crashes if the interface isn't resolvable. Double-check before binding.
                if hasMatchingInterface(for: address) {
                    print("[P2PNode] Binding mDNS to interface: \(device.name) (\(address))")
                    app.discovery.use(.mdns(interfaceAddress: address))
                    bound = true
                    break
                } else {
                    print(
                        "[P2PNode] Skipping interface \(device.name) (\(address)) — not resolvable for mDNS"
                    )
                }
            }

            if !bound {
                print(
                    "[P2PNode] Warning: No suitable network interface found for mDNS. Automatic discovery disabled."
                )
            }
        } else {
            print(
                "[P2PNode] mDNS discovery is disabled. Set FOLDERSYNC_ENABLE_MDNS=0/false to opt-out."
            )
        }

        // Register for peer discovery events
        app.discovery.onPeerDiscovered(self) { [weak self] (peerInfo: PeerInfo) in
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
        try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s

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
