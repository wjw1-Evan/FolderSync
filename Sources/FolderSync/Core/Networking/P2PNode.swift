import Darwin
import Foundation
import Network
import WebRTC

public class P2PNode: NSObject {
    private var lanDiscovery: LANDiscovery?
    @MainActor public let peerManager: PeerManager
    @MainActor public let registrationService: PeerRegistrationService

    // New WebRTC Stack
    public let webRTC: WebRTCManager
    public let signaling: TCPSignalingService

    // My PeerID (Backing property)
    public private(set) var peerID: PeerID?

    // PeerID, Addresses, SyncIDs
    public var onPeerDiscovered: ((PeerID, [String], [String]) -> Void)?

    // Callback when WebRTC DataChannel is ready
    public var onPeerConnected: ((String) -> Void)?

    // Callback for SyncEngine to handle requests
    // Request -> Response (Async)
    public var messageHandler: ((SyncRequest) async throws -> SyncResponse)?

    // Request tracking
    private var pendingRequests: [String: CheckedContinuation<SyncResponse, Error>] = [:]
    private let requestsQueue = DispatchQueue(label: "com.foldersync.p2p.requests")

    struct WebRTCFrame: Codable {
        let id: String
        let type: String  // "req" | "res"
        let payload: Data
    }

    public override init() {
        self.peerManager = MainActor.assumeIsolated { PeerManager() }
        self.registrationService = MainActor.assumeIsolated { PeerRegistrationService() }

        /// 使用 Google STUN Server
        self.webRTC = WebRTCManager(iceServers: ["stun:stun.l.google.com:19302"])
        self.signaling = TCPSignalingService()

        super.init()

        Task { @MainActor in
            self.peerManager.registrationService = self.registrationService
        }

        // Setup Delegates
        self.webRTC.delegate = self

        // Setup Signaling Callback
        self.signaling.onReceiveSignal = { [weak self] signal in
            self?.handleSignalingMessage(signal)
        }
    }

    // MARK: - Startup & Shutdown

    public func start() async throws {
        let folderSyncDir = AppPaths.appDirectory
        let peerIDFile = folderSyncDir.appendingPathComponent("peerid.txt")
        let password = AppPaths.isRunningTests ? "" : KeychainManager.loadOrCreatePassword()

        let peerID: PeerID
        if AppPaths.isRunningTests {
            peerID = PeerID.generate()
        } else if let savedPeerID = PeerID.load(from: peerIDFile, password: password) {
            peerID = savedPeerID
        } else {
            peerID = PeerID.generate()
            try? peerID.save(to: peerIDFile, password: password)
        }
        self.peerID = peerID

        // Start TCP Signaling Server (Port for exchanging SDP)
        let signalingPort = try signaling.startServer()
        AppLogger.syncPrint("[P2PNode] ✅ Signaling Server started on port: \(signalingPort)")

        // Setup LAN Discovery
        setupLANDiscovery(peerID: peerID.b58String, signalingPort: signalingPort)

        AppLogger.syncPrint(
            "[P2PNode] ✅ WebRTC Node Started. PeerID: \(peerID.b58String.prefix(8))...")
    }

    public func stop() async throws {
        lanDiscovery?.stop()
        signaling.stop()
        webRTC.stop()
        await peerManager.saveAllPeers()
    }

    // MARK: - Signaling & Discovery

    public func updateBroadcastSyncIDs(_ syncIDs: [String]) {
        lanDiscovery?.updateSyncIDs(syncIDs)
    }

    private func setupLANDiscovery(peerID: String, signalingPort: UInt16) {
        let discovery = LANDiscovery()
        discovery.onPeerDiscovered = { [weak self] discoveredID, address, addresses, syncIDs in
            guard let self = self, discoveredID != peerID else { return }

            // "addresses" here contains the Signaling Endpoint
            Task {
                await self.handleDiscoveredPeer(
                    peerID: discoveredID, addresses: addresses, syncIDs: syncIDs)
            }
        }

        // Broadcast our Signaling Address
        let localIP = getLocalIPAddress()
        let mySignalingAddr = "/ip4/\(localIP)/tcp/\(signalingPort)"
        discovery.start(peerID: peerID, listenAddresses: [mySignalingAddr], syncIDs: [])
        self.lanDiscovery = discovery
    }

    private func handleDiscoveredPeer(peerID: String, addresses: [String], syncIDs: [String]) async
    {
        guard let myPeerID = self.peerID?.b58String else { return }
        guard let peerIDObj = PeerID(cid: peerID) else { return }

        // Filter for valid signaling address
        var signalingIP: String?
        var signalingPort: UInt16?

        for addr in addresses {
            if let (ip, port) = AddressConverter.extractIPPort(from: addr) {
                if ip != "0.0.0.0" && ip != "127.0.0.1" {  // Prefer remote IP
                    signalingIP = ip
                    signalingPort = port
                    break
                }
                if ip == "127.0.0.1" && signalingIP == nil {
                    signalingIP = ip
                    signalingPort = port
                }
            }
        }

        guard let targetIP = signalingIP, let targetPort = signalingPort else { return }

        // Initiate connection if I am larger ID
        if myPeerID > peerID {
            // Check if already connected to prevent duplicate initiation (and crash)
            if !webRTC.hasConnection(for: peerID) {
                AppLogger.syncPrint(
                    "[P2PNode] 🤖 Initiating WebRTC to \(peerID.prefix(8))... Signal: \(targetIP):\(targetPort)"
                )

                webRTC.createOffer(for: peerID) { [weak self] sdp in
                    let msg = SignalingMessage(
                        type: "offer", sdp: sdp, candidate: nil, targetPeerID: peerID,
                        senderPeerID: myPeerID)
                    self?.signaling.send(signal: msg, to: targetIP, port: targetPort)
                }
            }
        }

        Task { @MainActor in
            peerManager.updateDeviceStatus(peerID, status: .online)
        }
        self.onPeerDiscovered?(peerIDObj, addresses, syncIDs)
    }

    private func handleSignalingMessage(_ msg: SignalingMessage) {
        if let sdp = msg.sdp {
            webRTC.handleRemoteSdp(sdp, from: msg.senderPeerID) { [weak self] answerSdp in
                guard let self = self, let answer = answerSdp else { return }

                Task {
                    // Start Answer back phase
                    // We need to know where to send it.
                    // Assuming we keep track or just use stored address in PeerManager
                    let addresses = await self.peerManager.getAddresses(for: msg.senderPeerID)
                    for addr in addresses {
                        if let (ip, port) = AddressConverter.extractIPPort(from: addr.description) {
                            let responseMsg = SignalingMessage(
                                type: "answer", sdp: answer, candidate: nil,
                                targetPeerID: msg.senderPeerID,
                                senderPeerID: self.peerID?.b58String ?? "")
                            self.signaling.send(signal: responseMsg, to: ip, port: port)
                            break
                        }
                    }
                }
            }
        } else if let candidate = msg.candidate {
            webRTC.handleRemoteCandidate(candidate, from: msg.senderPeerID)
        }
    }

    // MARK: - Sending Data

    public func sendRequest(_ request: SyncRequest, to peerID: String) async throws -> SyncResponse
    {
        let requestID = UUID().uuidString
        let requestData = try JSONEncoder().encode(request)
        let frame = WebRTCFrame(id: requestID, type: "req", payload: requestData)
        let frameData = try JSONEncoder().encode(frame)

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<SyncResponse, Error>) in
            requestsQueue.async {
                self.pendingRequests[requestID] = continuation
            }

            do {
                try webRTC.sendData(frameData, to: peerID)

                // Timeout logic
                Task {
                    try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                    self.requestsQueue.async {
                        if let storedContinuation = self.pendingRequests.removeValue(
                            forKey: requestID)
                        {
                            storedContinuation.resume(
                                throwing: NSError(
                                    domain: "P2PNode", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "Request timed out"]))
                        }
                    }
                }
            } catch {
                requestsQueue.async {
                    self.pendingRequests.removeValue(forKey: requestID)
                }
                continuation.resume(throwing: error)
            }
        }
    }

    public func sendData(_ data: Data, to peerID: String) throws {
        try webRTC.sendData(data, to: peerID)
    }

    // MARK: - Helpers
    private func getLocalIPAddress() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }

        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            guard let ifaAddr = interface.ifa_addr else { continue }
            if ifaAddr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // Filter common interfaces
                if name.hasPrefix("en") || name.hasPrefix("eth") || name.hasPrefix("wlan") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        ifaAddr, socklen_t(ifaAddr.pointee.sa_len), &hostname,
                        socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                    let ip = String(cString: hostname)
                    if ip != "127.0.0.1" && !ip.isEmpty {
                        address = ip
                        break
                    }
                }
            }
        }
        return address
    }
}

// MARK: - WebRTC Delegate
extension P2PNode: WebRTCManagerDelegate {
    func webRTCManager(
        _ manager: WebRTCManager, didDiscoverLocalCandidate candidate: IceCandidate,
        for peerID: String
    ) {
        Task {
            let addresses = await self.peerManager.getAddresses(for: peerID)
            for addr in addresses {
                if let (ip, port) = AddressConverter.extractIPPort(from: addr.description) {
                    let msg = SignalingMessage(
                        type: "candidate", sdp: nil, candidate: candidate, targetPeerID: peerID,
                        senderPeerID: self.peerID?.b58String ?? "")
                    self.signaling.send(signal: msg, to: ip, port: port)
                    break
                }
            }
        }
    }

    func webRTCManager(
        _ manager: WebRTCManager, didChangeConnectionState state: RTCIceConnectionState,
        for peerID: String
    ) {
        AppLogger.syncPrint("[P2PNode] WebRTC State for \(peerID.prefix(8)): \(state.rawValue)")
        if state == .connected {
            Task { @MainActor in
                peerManager.updateDeviceStatus(peerID, status: .online)
            }
        }
    }

    func webRTCManager(
        _ manager: WebRTCManager, didChangeDataChannelState state: RTCDataChannelState,
        for peerID: String
    ) {
        AppLogger.syncPrint(
            "[P2PNode] DataChannel State for \(peerID.prefix(8)): \(state.rawValue)")
        if state == .open {
            self.onPeerConnected?(peerID)
        }
    }

    func webRTCManager(_ manager: WebRTCManager, didReceiveData data: Data, from peerID: String) {
        guard let frame = try? JSONDecoder().decode(WebRTCFrame.self, from: data) else { return }

        if frame.type == "req" {
            // Handle Request
            Task {
                guard let messageHandler = messageHandler else { return }
                if let request = try? JSONDecoder().decode(SyncRequest.self, from: frame.payload) {
                    do {
                        let response = try await messageHandler(request)
                        let responseData = try JSONEncoder().encode(response)
                        let responseFrame = WebRTCFrame(
                            id: frame.id, type: "res", payload: responseData)
                        let responseFrameData = try JSONEncoder().encode(responseFrame)
                        try self.webRTC.sendData(responseFrameData, to: peerID)
                    } catch {
                        print("Handler error: \(error)")
                    }
                }
            }
        } else if frame.type == "res" {
            // Handle Response
            requestsQueue.async {
                if let continuation = self.pendingRequests.removeValue(forKey: frame.id) {
                    if let response = try? JSONDecoder().decode(
                        SyncResponse.self, from: frame.payload)
                    {
                        continuation.resume(returning: response)
                    } else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "P2PNode", code: -3,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "Failed to decode response payload"
                                ]))
                    }
                }
            }
        }
    }
}
