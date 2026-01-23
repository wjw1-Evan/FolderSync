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
            if let addr = P2PNode.getSafeMDNSInterfaceAddress() {
                print("[P2PNode] Enabling mDNS on address: \(addr)")
                app.discovery.use(.mdns(interfaceAddress: addr))
            } else {
                print("[P2PNode] Skipping mDNS: No interface found with both IPv4 and IPv6 (required by LibP2P)")
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
    /// Returns a SocketAddress for an interface that has BOTH IPv4 and IPv6 addresses.
    /// This is required to satisfy the LibP2PMDNS library's internal force-unwraps.
    private static func getSafeMDNSInterfaceAddress() -> SocketAddress? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        // First, group interfaces by name and check which ones have what families
        var interfaceMap: [String: Set<Int32>] = [:]
        var addressMap: [String: SocketAddress] = [:]

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr?.pointee {
            defer { ptr = current.ifa_next }
            guard let nameC = current.ifa_name else { continue }
            let name = String(cString: nameC)
            
            let flags = Int32(current.ifa_flags)
            guard (flags & IFF_LOOPBACK) == 0, (flags & IFF_UP) != 0 else { continue }
            
            if let addr = current.ifa_addr {
                let family = Int32(addr.pointee.sa_family)
                interfaceMap[name, default: []].insert(family)
                
                if family == AF_INET {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(MemoryLayout<sockaddr_in>.size), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: hostname)
                        addressMap[name] = try? SocketAddress(ipAddress: ip, port: 0)
                    }
                }
            }
        }

        // Return the first interface that has both IPv4 (AF_INET) and IPv6 (AF_INET6)
        for (name, families) in interfaceMap {
            if families.contains(AF_INET) && families.contains(AF_INET6) {
                if let addr = addressMap[name] {
                    print("[P2PNode] Found suitable interface for mDNS: \(name)")
                    return addr
                }
            }
        }
        
        return nil
    }
}
