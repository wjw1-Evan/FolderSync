import Darwin
import Foundation
import LibP2P
import NIOCore

public class P2PNode {
    public var app: Application?
    private var lanDiscovery: LANDiscovery?

    public init() {}
    
    /// Setup LAN discovery using UDP broadcast
    private func setupLANDiscovery(peerID: String, listenAddresses: [String] = []) {
        let discovery = LANDiscovery()
        discovery.onPeerDiscovered = { [weak self] discoveredPeerID, address, peerAddresses in
            print("[P2PNode] LAN discovery found peer: \(discoveredPeerID) at \(address) with addresses: \(peerAddresses)")
            // Try to connect to the discovered peer via libp2p
            Task { @MainActor in
                await self?.connectToDiscoveredPeer(peerID: discoveredPeerID, addresses: peerAddresses)
            }
        }
        discovery.start(peerID: peerID, listenAddresses: listenAddresses)
        self.lanDiscovery = discovery
        print("[P2PNode] LAN discovery enabled using UDP broadcast. Automatic peer discovery active.")
    }
    
    /// Connect to a peer discovered via LAN discovery
    private func connectToDiscoveredPeer(peerID: String, addresses: [String]) async {
        guard app != nil else { return }
        
        // Try to parse the peerID string to PeerID object
        guard let peerIDObj = try? PeerID(cid: peerID) else {
            print("[P2PNode] Failed to parse peerID: \(peerID)")
            return
        }
        
        // Try to connect using the provided addresses
        var foundAddress = false
        for addressStr in addresses {
            // Try to parse as Multiaddr
            if let multiaddr = try? Multiaddr(addressStr) {
                print("[P2PNode] Found peer \(peerID.prefix(8)) at \(multiaddr)")
                // Note: libp2p will automatically try to connect when SyncManager makes a request
                // The address information is stored in the peer store implicitly when we trigger the callback
                foundAddress = true
                break
            }
        }
        
        if !foundAddress && !addresses.isEmpty {
            print("[P2PNode] Warning: Could not parse any addresses for \(peerID.prefix(8)): \(addresses)")
        }
        
        // Trigger peer discovery callback so SyncManager can try to sync
        // libp2p's newRequest will automatically establish connection when needed
        // If addresses were provided, the connection should use them
        print("[P2PNode] Triggering peer discovery callback for \(peerID.prefix(8))")
        await MainActor.run {
            self.onPeerDiscovered?(peerIDObj)
        }
    }

    public var onPeerDiscovered: ((PeerID) -> Void)?
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
            
            // 删除整个目录并重新创建，确保彻底清理所有密钥相关文件
            let fileManager = FileManager.default
            do {
                // 尝试删除整个目录
                if fileManager.fileExists(atPath: folderSyncDir.path) {
                    try fileManager.removeItem(at: folderSyncDir)
                    print("[P2PNode] 已删除旧的 FolderSync 目录")
                }
                // 重新创建目录
                try fileManager.createDirectory(at: folderSyncDir, withIntermediateDirectories: true)
                print("[P2PNode] 已重新创建 FolderSync 目录")
            } catch {
                print("[P2PNode] ⚠️ 删除目录时出错: \(error.localizedDescription)")
                // 如果删除目录失败，尝试删除目录内的所有文件
                if let files = try? fileManager.contentsOfDirectory(at: folderSyncDir, includingPropertiesForKeys: nil) {
                    for file in files {
                        try? fileManager.removeItem(at: file)
                        print("[P2PNode] 已删除文件: \(file.lastPathComponent)")
                    }
                }
            }
            
            // 重新生成密码（确保使用新密码）
            let newPassword = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32).description
            _ = KeychainManager.savePassword(newPassword)
            print("[P2PNode] 已生成新密码并保存到 Keychain")
            
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

        // Explicitly configure TCP to listen on all interfaces
        // Using port 0 allows the OS to assign any available port
        app.listen(.tcp(host: "0.0.0.0", port: 0))

        // Enable LAN discovery using UDP broadcast (more reliable than mDNS)
        // Will update addresses after startup
        setupLANDiscovery(peerID: app.peerID.b58String, listenAddresses: [])

        // TODO: DHT广域网发现 - 需要添加 DHT 包并配置:
        // app.dht.initialize()
        // app.dht.use(KademliaDHT(...))
        // app.discovery.use(.dht(...))
        // 需要添加 swift-libp2p-dht 或类似包到 Package.swift
        
        // TODO: AutoNAT 和 Circuit Relay - 需要配置:
        // app.use(.autonat)
        // app.use(.circuitRelay(...))
        // 需要检查 swift-libp2p 是否提供这些模块
        
        // Register for peer discovery events (from libp2p's discovery mechanisms)
        app.discovery.onPeerDiscovered(self) { [weak self] (peerInfo: PeerInfo) in
            print("[P2PNode] libp2p discovered peer: \(peerInfo.peer.b58String)")
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

        // Update LAN discovery with actual listen addresses
        let addresses = app.listenAddresses.map { $0.description }
        lanDiscovery?.updateListenAddresses(addresses)

        // 详细日志输出
        print("\n[P2PNode] ========== P2P 节点启动状态 ==========")
        print("[P2PNode] PeerID: \(app.peerID.b58String)")
        print("[P2PNode] 监听地址数量: \(app.listenAddresses.count)")
        
        if app.listenAddresses.isEmpty {
            print("[P2PNode] ⚠️ 警告: 未检测到监听地址，libp2p 可能未成功启动")
            print("[P2PNode] 请检查:")
            print("[P2PNode]   1. 网络权限是否已授予")
            print("[P2PNode]   2. 防火墙是否阻止了端口")
            print("[P2PNode]   3. 是否有其他程序占用了端口")
        } else {
            print("[P2PNode] ✅ 监听地址列表:")
            for (index, addr) in app.listenAddresses.enumerated() {
                print("[P2PNode]   [\(index + 1)] \(addr)")
            }
            print("[P2PNode] ✅ Ready for connections. Listening on: \(app.listenAddresses)")
        }
        
        // 检查 LANDiscovery 状态
        if let discovery = lanDiscovery {
            print("[P2PNode] ✅ LAN Discovery 已启用 (UDP 广播端口: 8765)")
        } else {
            print("[P2PNode] ❌ LAN Discovery 未启用")
        }
        
        print("[P2PNode] ======================================\n")
    }

    public func announce(service: String) async throws {
        guard let app = app else { return }
        // Announce a service (like a sync group ID) on the network
        _ = try await app.discovery.announce(.service(service)).get()
        print("Announced service: \(service)")
    }

    public func stop() async throws {
        lanDiscovery?.stop()
        try await app?.asyncShutdown()
    }

    public var peerID: String? {
        app?.peerID.b58String
    }

    public var listenAddresses: [String] {
        app?.listenAddresses.map { $0.description } ?? []
    }
}
