import Darwin
import Foundation
import Network
import WebRTC

@MainActor
public class P2PNode: NSObject {
    private var lanDiscovery: LANDiscovery?
    @MainActor public let peerManager: PeerManager
    @MainActor public let registrationService: PeerRegistrationService

    // New WebRTC Stack
    public let webRTC: WebRTCManager
    public let signaling: TCPSignalingService

    // My PeerID (Backing property)
    public private(set) var peerID: PeerID?
    /// The actual port the signaling server is listening on
    public private(set) var signalingPort: UInt16?

    // PeerID, Addresses, SyncIDs
    public var onPeerDiscovered: ((PeerID, [String], [String]) -> Void)?

    // Callback when WebRTC DataChannel is ready
    public var onPeerConnected: ((String) -> Void)?

    // Callback for SyncEngine to handle requests
    // Request -> Response (Async)
    public var messageHandler: ((SyncRequest) async throws -> SyncResponse)?

    // Request tracking
    private actor RequestTracker {
        private var pendingRequests: [String: CheckedContinuation<SyncResponse, Error>] = [:]

        func store(id: String, continuation: CheckedContinuation<SyncResponse, Error>) {
            pendingRequests[id] = continuation
        }

        func remove(id: String) -> CheckedContinuation<SyncResponse, Error>? {
            return pendingRequests.removeValue(forKey: id)
        }
    }
    private let requestTracker = RequestTracker()

    // Connection tracking to prevent race conditions
    // 改进：保存完整的连接信息，支持自动重试
    struct PendingConnectionInfo: Sendable {
        let peerID: String
        let targetIP: String
        let targetPort: UInt16
        let startTime: Date
        var retryCount: Int = 0
        static let maxRetries = 3
        static let connectionTimeout: TimeInterval = 20.0  // 单次连接超时
    }

    private actor ConnectionTracker {
        private var pendingConnections: [String: PendingConnectionInfo] = [:]

        func get(peerID: String) -> PendingConnectionInfo? {
            return pendingConnections[peerID]
        }

        func set(peerID: String, info: PendingConnectionInfo) {
            pendingConnections[peerID] = info
        }

        func remove(peerID: String) -> PendingConnectionInfo? {
            return pendingConnections.removeValue(forKey: peerID)
        }

        func update(peerID: String, transform: (inout PendingConnectionInfo) -> Void)
            -> PendingConnectionInfo?
        {
            if var info = pendingConnections[peerID] {
                transform(&info)
                pendingConnections[peerID] = info
                return info
            }
            return nil
        }
    }
    private let connectionTracker = ConnectionTracker()

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
        self.signalingPort = signalingPort
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
            var shouldConnect = false

            // 检查是否有活跃连接
            if webRTC.hasConnection(for: peerID) {
                // 已有连接，不需要重新建立
            } else if let existingInfo = await connectionTracker.get(peerID: peerID) {
                // 检查是否超时
                let elapsed = Date().timeIntervalSince(existingInfo.startTime)
                if elapsed > PendingConnectionInfo.connectionTimeout {
                    // 超时，如果还有重试次数则重试
                    if existingInfo.retryCount < PendingConnectionInfo.maxRetries {
                        let newInfo = PendingConnectionInfo(
                            peerID: peerID,
                            targetIP: targetIP,
                            targetPort: targetPort,
                            startTime: Date(),
                            retryCount: existingInfo.retryCount + 1
                        )
                        await connectionTracker.set(peerID: peerID, info: newInfo)
                        shouldConnect = true
                        AppLogger.syncPrint(
                            "[P2PNode] ⏳ Connection attempt to \(peerID.prefix(8)) timed out, retrying (\(newInfo.retryCount)/\(PendingConnectionInfo.maxRetries))"
                        )
                    } else {
                        // 达到最大重试次数，放弃
                        _ = await connectionTracker.remove(peerID: peerID)
                        AppLogger.syncPrint(
                            "[P2PNode] ❌ Connection to \(peerID.prefix(8)) failed after \(PendingConnectionInfo.maxRetries) retries"
                        )
                    }
                }
                // 否则正在连接中，跳过
            } else {
                // 没有活跃连接也没有待处理连接，开始新连接
                let info = PendingConnectionInfo(
                    peerID: peerID,
                    targetIP: targetIP,
                    targetPort: targetPort,
                    startTime: Date()
                )
                await connectionTracker.set(peerID: peerID, info: info)
                shouldConnect = true
            }

            if shouldConnect {
                initiateConnection(peerID: peerID, targetIP: targetIP, targetPort: targetPort)
            }
        }

        Task { @MainActor in
            peerManager.updateDeviceStatus(peerID, status: .online)
        }
        self.onPeerDiscovered?(peerIDObj, addresses, syncIDs)
    }

    /// 主动发起 WebRTC 连接
    /// 注意：pending 状态将在 DataChannel 成功连接后通过 onPeerConnected 移除，
    /// 或者在超时后由 handleDiscoveredPeer 中的超时检测触发重试
    private func initiateConnection(peerID: String, targetIP: String, targetPort: UInt16) {
        let myPeerID = self.peerID?.b58String ?? ""
        AppLogger.syncPrint(
            "[P2PNode] 🤖 Initiating WebRTC to \(peerID.prefix(8))... Signal: \(targetIP):\(targetPort)"
        )

        webRTC.createOffer(for: peerID) { [weak self] sdp in
            guard let self = self else { return }

            // 不再在这里移除 pending 状态，让超时检测处理失败情况
            // pending 状态将在 markConnectionEstablished 中移除

            let msg = SignalingMessage(
                type: "offer", sdp: sdp, candidate: nil, targetPeerID: peerID,
                senderPeerID: myPeerID)
            self.signaling.send(signal: msg, to: targetIP, port: targetPort)

            AppLogger.syncPrint(
                "[P2PNode] 📤 Sent SDP Offer to \(peerID.prefix(8))"
            )
        }
    }

    /// 标记连接已建立，清除 pending 状态
    private func markConnectionEstablished(for peerID: String) async {
        if await connectionTracker.remove(peerID: peerID) != nil {
            AppLogger.syncPrint(
                "[P2PNode] ✅ Connection established to \(peerID.prefix(8)), cleared pending state"
            )
        }
    }

    /// 确保已经启动连接
    private func ensureConnected(to peerID: String) async {
        // 如果已有活跃连接且 DataChannel 就绪，直接返回
        if webRTC.hasConnection(for: peerID) && webRTC.isDataChannelReady(for: peerID) {
            return
        }

        // 获取地址信息
        let addresses = peerManager.getAddresses(for: peerID)
        var signalingIP: String?
        var signalingPort: UInt16?

        for addr in addresses {
            if let (ip, port) = AddressConverter.extractIPPort(from: addr.description) {
                signalingIP = ip
                signalingPort = port
                break
            }
        }

        guard let targetIP = signalingIP, let targetPort = signalingPort else {
            AppLogger.syncPrint(
                "[P2PNode] ⚠️ Cannot ensureConnected: No signaling address for \(peerID.prefix(8))")
            return
        }

        var shouldConnect = false

        // 如果已有连接（即使 DataChannel 还没ready），等待即可
        if webRTC.hasConnection(for: peerID) {
            return
        }

        if let existingInfo = await connectionTracker.get(peerID: peerID) {
            // 检查是否超时
            let elapsed = Date().timeIntervalSince(existingInfo.startTime)
            if elapsed > PendingConnectionInfo.connectionTimeout {
                // 超时，清除旧连接并重试
                webRTC.removeConnection(for: peerID)
                if existingInfo.retryCount < PendingConnectionInfo.maxRetries {
                    let newInfo = PendingConnectionInfo(
                        peerID: peerID,
                        targetIP: targetIP,
                        targetPort: targetPort,
                        startTime: Date(),
                        retryCount: existingInfo.retryCount + 1
                    )
                    await connectionTracker.set(peerID: peerID, info: newInfo)
                    shouldConnect = true
                    AppLogger.syncPrint(
                        "[P2PNode] ⏳ ensureConnected: Connection attempt to \(peerID.prefix(8)) timed out, retrying (\(newInfo.retryCount)/\(PendingConnectionInfo.maxRetries))"
                    )
                } else {
                    _ = await connectionTracker.remove(peerID: peerID)
                    AppLogger.syncPrint(
                        "[P2PNode] ❌ ensureConnected: Connection to \(peerID.prefix(8)) failed after max retries"
                    )
                }
            } else {
                // 正在连接中，等待即可
            }
        } else {
            // 没有待处理连接，开始新连接
            let info = PendingConnectionInfo(
                peerID: peerID,
                targetIP: targetIP,
                targetPort: targetPort,
                startTime: Date()
            )
            await connectionTracker.set(peerID: peerID, info: info)
            shouldConnect = true

            AppLogger.syncPrint(
                "[P2PNode] 🔗 ensureConnected: Starting new connection to \(peerID.prefix(8))"
            )
        }

        if shouldConnect {
            initiateConnection(peerID: peerID, targetIP: targetIP, targetPort: targetPort)
        }
    }

    private func handleSignalingMessage(_ msg: SignalingMessage) {
        if let sdp = msg.sdp {
            webRTC.handleRemoteSdp(sdp, from: msg.senderPeerID) { [weak self] answerSdp in
                guard let self = self, let answer = answerSdp else { return }

                Task {
                    // Start Answer back phase
                    // We need to know where to send it.
                    // Assuming we keep track or just use stored address in PeerManager
                    let addresses = self.peerManager.getAddresses(for: msg.senderPeerID)
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
        // 确保连接已启动
        await ensureConnected(to: peerID)

        // 先等待 DataChannel 就绪
        AppLogger.syncPrint("[P2PNode] ⏳ Waiting for DataChannel to \(peerID.prefix(8))...")
        let isReady = await webRTC.waitForDataChannelReady(for: peerID, timeout: 30.0)
        guard isReady else {
            // 在抛出异常前记录底层状态
            let pc = webRTC.getPeerConnection(for: peerID)
            let iceState = pc?.iceConnectionState.rawValue ?? -1
            let sigState = pc?.signalingState.rawValue ?? -1
            AppLogger.syncPrint(
                "[P2PNode] ❌ DataChannel wait timeout for \(peerID.prefix(8)) (ICE=\(iceState), Sig=\(sigState)). Removing connection for retry."
            )
            // 失败时清除连接状态，让下一次重试可以重新发起全新的连接
            webRTC.removeConnection(for: peerID)

            // 同时清除 pending 状态
            _ = await connectionTracker.remove(peerID: peerID)

            throw NSError(
                domain: "P2PNode", code: -3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "DataChannel not ready after waiting 30s (ICE=\(iceState), Sig=\(sigState))"
                ])
        }

        let requestID = UUID().uuidString
        let requestData = try JSONEncoder().encode(request)
        let frame = WebRTCFrame(id: requestID, type: "req", payload: requestData)
        let frameData = try JSONEncoder().encode(frame)

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<SyncResponse, Error>) in
            Task {
                await self.requestTracker.store(id: requestID, continuation: continuation)

                if frameData.count > 1024 * 1024 {
                    AppLogger.syncPrint(
                        "[P2PNode] 📡 Sending large frame: \(frameData.count / 1024) KB (type: \(frame.type), id: \(frame.id))"
                    )
                }

                do {
                    try await webRTC.sendData(frameData, to: peerID)

                    // Timeout logic: 增加到 120秒，给大文件夹初始扫描留出充足时间
                    try await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                    if let storedContinuation = await self.requestTracker.remove(id: requestID) {
                        AppLogger.syncPrint(
                            "[P2PNode] ⚠️ Request timed out: \(requestID) (peer: \(peerID.prefix(8)))"
                        )
                        storedContinuation.resume(
                            throwing: NSError(
                                domain: "P2PNode", code: -2,
                                userInfo: [NSLocalizedDescriptionKey: "Request timed out"]))
                    }
                } catch {
                    if let continuation = await self.requestTracker.remove(id: requestID) {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    public func sendData(_ data: Data, to peerID: String) async throws {
        try await webRTC.sendData(data, to: peerID)
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
@MainActor
extension P2PNode: WebRTCManagerDelegate {
    func webRTCManager(
        _ manager: WebRTCManager, didDiscoverLocalCandidate candidate: IceCandidate,
        for peerID: String
    ) {
        Task {
            let addresses = self.peerManager.getAddresses(for: peerID)
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

        switch state {
        case .connected:
            Task { @MainActor in
                peerManager.updateDeviceStatus(peerID, status: .online)
            }
        case .failed, .closed, .disconnected:
            // 连接失败，清除 pending 状态让下次可以重试
            Task {
                _ = await connectionTracker.remove(peerID: peerID)
            }

            if state == .failed {
                AppLogger.syncPrint("[P2PNode] ❌ ICE connection failed for \(peerID.prefix(8))")
            }
        default:
            break
        }
    }

    func webRTCManager(
        _ manager: WebRTCManager, didChangeDataChannelState state: RTCDataChannelState,
        for peerID: String
    ) {
        AppLogger.syncPrint(
            "[P2PNode] DataChannel State for \(peerID.prefix(8)): \(state.rawValue)")

        switch state {
        case .open:
            // DataChannel 成功打开，清除 pending 状态
            Task {
                await markConnectionEstablished(for: peerID)
            }
            self.onPeerConnected?(peerID)
        case .closed, .closing:
            // DataChannel 关闭，清除 pending 状态让下次可以重试
            Task {
                _ = await connectionTracker.remove(peerID: peerID)
            }
        default:
            break
        }
    }

    func webRTCManager(_ manager: WebRTCManager, didReceiveData data: Data, from peerID: String) {
        let decoder = JSONDecoder()

        guard
            let frame: WebRTCFrame = {
                do {
                    return try decoder.decode(WebRTCFrame.self, from: data)
                } catch {
                    AppLogger.syncPrint("[P2PNode] ❌ Failed to decode WebRTCFrame: \(error)")
                    return nil
                }
            }()
        else { return }

        if frame.type == "req" {
            // Handle Request
            Task {
                guard let messageHandler = messageHandler else { return }
                do {
                    let request = try decoder.decode(SyncRequest.self, from: frame.payload)
                    let response = try await messageHandler(request)
                    let responseData = try JSONEncoder().encode(response)
                    let responseFrame = WebRTCFrame(
                        id: frame.id, type: "res", payload: responseData)
                    let responseFrameData = try JSONEncoder().encode(responseFrame)
                    if responseFrameData.count > 1024 * 1024 {
                        AppLogger.syncPrint(
                            "[P2PNode] 📡 Sending large response: \(responseFrameData.count / 1024) KB (id: \(frame.id))"
                        )
                    }

                    // 确保 DataChannel 就绪后再发送响应
                    _ = await self.webRTC.waitForDataChannelReady(for: peerID, timeout: 5.0)
                    try await self.webRTC.sendData(responseFrameData, to: peerID)
                } catch {
                    AppLogger.syncPrint("[P2PNode] ❌ Handler error for req \(frame.id): \(error)")
                }
            }
        } else if frame.type == "res" {
            // Handle Response
            Task {
                if let continuation = await self.requestTracker.remove(id: frame.id) {
                    do {
                        let response = try decoder.decode(SyncResponse.self, from: frame.payload)
                        continuation.resume(returning: response)
                    } catch {
                        AppLogger.syncPrint(
                            "[P2PNode] ❌ Failed to decode response \(frame.id) payload: \(error)")
                        continuation.resume(
                            throwing: NSError(
                                domain: "P2PNode", code: -3,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "Failed to decode response payload: \(error.localizedDescription)"
                                ]))
                    }
                }
            }
        }
    }
}
