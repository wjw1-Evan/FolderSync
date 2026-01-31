import Foundation
import WebRTC

protocol WebRTCManagerDelegate: AnyObject {
    func webRTCManager(
        _ manager: WebRTCManager, didDiscoverLocalCandidate candidate: IceCandidate,
        for peerID: String)
    func webRTCManager(
        _ manager: WebRTCManager, didChangeConnectionState state: RTCIceConnectionState,
        for peerID: String)
    func webRTCManager(
        _ manager: WebRTCManager, didChangeDataChannelState state: RTCDataChannelState,
        for peerID: String)
    func webRTCManager(_ manager: WebRTCManager, didReceiveData data: Data, from peerID: String)
}

public class WebRTCManager: NSObject {
    private let factory: RTCPeerConnectionFactory
    // peerID -> RTCPeerConnection
    private var peerConnections: [String: RTCPeerConnection] = [:]
    // peerID -> RTCDataChannel
    private var dataChannels: [String: RTCDataChannel] = [:]
    // Waiter class to allow reference comparison for CheckedContinuation
    private class Waiter {
        let continuation: CheckedContinuation<Bool, Never>
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    }
    // peerID -> Continuations waiting for connection
    private var pendingReadyContinuations: [String: [Waiter]] = [:]

    private let lock = NSLock()

    weak var delegate: WebRTCManagerDelegate?

    private let iceServers: [String]

    private static let rtcInitialized: Void = {
        RTCInitializeSSL()
        return ()
    }()

    init(iceServers: [String] = ["stun:stun.l.google.com:19302"]) {
        // Initialize WebRTC
        _ = WebRTCManager.rtcInitialized

        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
        self.iceServers = iceServers
        super.init()
    }

    deinit {
        stop()
    }

    public func stop() {
        lock.lock()
        let pcValues = Array(peerConnections.values)
        let dcValues = Array(dataChannels.values)
        let peerIDs = Array(peerConnections.keys)
        peerConnections.removeAll()
        dataChannels.removeAll()
        pcToPeerID.removeAll()
        lock.unlock()

        for peerID in peerIDs {
            resumeContinuations(for: peerID, result: false)
        }

        for dc in dcValues {
            dc.close()
        }
        for pc in pcValues {
            pc.close()
        }
    }

    public func hasConnection(for peerID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return peerConnections[peerID] != nil
    }

    /// 检查 DataChannel 是否就绪（已打开）
    public func isDataChannelReady(for peerID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let dc = dataChannels[peerID] else { return false }
        return dc.readyState == .open
    }

    /// 等待 DataChannel 就绪，带超时
    public func waitForDataChannelReady(for peerID: String, timeout: TimeInterval = 15.0) async
        -> Bool
    {
        // 1. 立即检查
        if isDataChannelReady(for: peerID) {
            return true
        }

        // 2. 检查连接状态，如果已经处于失败状态，直接返回
        lock.lock()
        let pc = peerConnections[peerID]
        let state = pc?.iceConnectionState
        lock.unlock()

        if let state = state, state == .failed || state == .closed {
            AppLogger.syncPrint(
                "[WebRTC] ❌ Cannot wait for DataChannel: Connection already in state \(state.rawValue)"
            )
            return false
        }

        return await withCheckedContinuation { continuation in
            let waiter = Waiter(continuation)

            lock.lock()
            // 再次检查就绪状态（在锁内检查以避免竞态）
            if let dc = dataChannels[peerID], dc.readyState == .open {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }

            var list = pendingReadyContinuations[peerID] ?? []
            list.append(waiter)
            pendingReadyContinuations[peerID] = list
            lock.unlock()

            // 超时处理：只负责这个特定的 continuation
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))

                self.lock.lock()
                // 检查是否还在列表中（即尚未被状态变化逻辑 resume）
                if var currentList = self.pendingReadyContinuations[peerID],
                    let index = currentList.firstIndex(where: { $0 === waiter })
                {
                    currentList.remove(at: index)
                    self.pendingReadyContinuations[peerID] = currentList
                    self.lock.unlock()

                    AppLogger.syncPrint(
                        "[WebRTC] ⏳ waitForDataChannelReady timeout for \(peerID.prefix(8))")
                    continuation.resume(returning: false)
                } else {
                    self.lock.unlock()
                }
            }
        }
    }

    private func resumeContinuations(for peerID: String, result: Bool, onlyOne: Bool = false) {
        lock.lock()
        guard var list = pendingReadyContinuations[peerID], !list.isEmpty else {
            lock.unlock()
            return
        }

        if onlyOne {
            let first = list.removeFirst()
            pendingReadyContinuations[peerID] = list
            lock.unlock()
            first.continuation.resume(returning: result)
        } else {
            pendingReadyContinuations[peerID] = []
            lock.unlock()
            for waiter in list {
                waiter.continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Connection Management

    /// 发起连接 (Offer)
    func connect(to peerID: String) {
        let rtcConfig = RTCConfiguration()
        rtcConfig.iceServers = [RTCIceServer(urlStrings: iceServers)]
        rtcConfig.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])

        guard
            let peerConnection = factory.peerConnection(
                with: rtcConfig, constraints: constraints, delegate: self)
        else {
            print("[WebRTC] Failed to create PeerConnection")
            return
        }

        // 存储连接
        lock.lock()
        self.peerConnections[peerID] = peerConnection
        lock.unlock()

        // 创建 Data Channel
        let dataChannelConfig = RTCDataChannelConfiguration()
        dataChannelConfig.isOrdered = true
        // dataChannelConfig.maxRetransmits = 3 // 可选：配置重传策略

        if let dataChannel = peerConnection.dataChannel(
            forLabel: "sync-data", configuration: dataChannelConfig)
        {
            dataChannel.delegate = self
            lock.lock()
            self.dataChannels[peerID] = dataChannel
            lock.unlock()
        }

        // 创建 Offer
        peerConnection.offer(for: constraints) { [weak self] sdp, error in
            guard let self = self, let sdp = sdp else { return }

            peerConnection.setLocalDescription(sdp) { error in
                if let error = error {
                    print("[WebRTC] Set Local Description Error: \(error)")
                    return
                }
                // 发送 Offer
                // 这里需要通过 SignalingClient 发送，这一层最好通过 Delegate 或 Closure 回调出去
                // 因为 WebRTCManager 只负责 WebRTC 逻辑
                // 但为了简化，我们在 createOffer/Answer 成功后不直接发，而是依赖 ICE Candidate 收集
                // 下面的 sdp 需要通过信令发出去
                self.delegate?.webRTCManager(
                    self,
                    didDiscoverLocalCandidate: IceCandidate(
                        from: RTCIceCandidate(sdp: "", sdpMLineIndex: 0, sdpMid: nil)), for: peerID)  // Hack: 这里的逻辑有点乱，应该有一个明确的 delegate 方法发送 SDP
            }

            // 修正：我们需要明确的回调来发送 SDP，不能复用 Candidate 回调
            // 实际上这里的 createOffer 是异步的，我们需要一个机制把 SDP 传出去
        }
    }

    // 重构 Connect 逻辑：
    // connect() -> create PeerConnection -> create DataChannel -> create Offer -> setLocalDescription -> return SDP via callback

    func createOffer(for peerID: String, completion: @escaping (SessionDescription) -> Void) {
        let rtcConfig = RTCConfiguration()
        rtcConfig.iceServers = [RTCIceServer(urlStrings: iceServers)]
        rtcConfig.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])

        guard
            let peerConnection = factory.peerConnection(
                with: rtcConfig, constraints: constraints, delegate: self)
        else { return }

        // 记录关联的 peerID，这在 delegate 回调中需要用到
        // 由于 RTCPeerConnectionDelegate 不带 peerID 上下文，我们需要一个 Wrapper 或者 Map
        // 简单起见，我们假设 PeerConnection 实例地址作为 Key，映射回 peerID
        self.register(peerConnection: peerConnection, for: peerID)

        // Create Data Channel (Initiator creates channel)
        let dcConfig = RTCDataChannelConfiguration()
        if let dc = peerConnection.dataChannel(forLabel: "sync-data", configuration: dcConfig) {
            dc.delegate = self
            lock.lock()
            self.dataChannels[peerID] = dc
            lock.unlock()
        }

        peerConnection.offer(for: constraints) { [weak self] sdp, error in
            guard let sdp = sdp else { return }
            peerConnection.setLocalDescription(sdp) { error in
                if error == nil {
                    DispatchQueue.main.async {
                        completion(SessionDescription(from: sdp))
                    }
                }
            }
        }
    }

    func handleRemoteSdp(
        _ sessionDescription: SessionDescription, from peerID: String,
        completion: ((SessionDescription?) -> Void)? = nil
    ) {
        let rtcSdp = sessionDescription.rtcSessionDescription

        // 检查是否存在现有的 PeerConnection
        lock.lock()
        var peerConnection = peerConnections[peerID]
        lock.unlock()

        if peerConnection == nil {
            // 被动方 (Answerer) 初始化
            let rtcConfig = RTCConfiguration()
            rtcConfig.iceServers = [RTCIceServer(urlStrings: iceServers)]
            rtcConfig.sdpSemantics = .unifiedPlan
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])

            guard
                let newPc = factory.peerConnection(
                    with: rtcConfig, constraints: constraints, delegate: self)
            else { return }
            self.register(peerConnection: newPc, for: peerID)
            peerConnection = newPc
        }

        guard let pc = peerConnection else { return }

        pc.setRemoteDescription(rtcSdp) { error in
            if let error = error {
                print("[WebRTC] Set Remote Description Error: \(error)")
                return
            }

            // 如果是 Offer，则创建 Answer
            if rtcSdp.type == .offer {
                let constraints = RTCMediaConstraints(
                    mandatoryConstraints: nil, optionalConstraints: nil)
                pc.answer(for: constraints) { [weak self] sdp, error in
                    guard let sdp = sdp else { return }
                    pc.setLocalDescription(sdp) { error in
                        if error == nil {
                            DispatchQueue.main.async {
                                completion?(SessionDescription(from: sdp))
                            }
                        }
                    }
                }
            }
        }
    }

    func handleRemoteCandidate(_ candidate: IceCandidate, from peerID: String) {
        lock.lock()
        let pc = peerConnections[peerID]
        lock.unlock()

        guard let pc = pc else { return }
        pc.add(candidate.rtcIceCandidate)
    }

    func sendData(_ data: Data, to peerID: String) throws {
        lock.lock()
        let dc = dataChannels[peerID]
        lock.unlock()

        guard let dc = dc else {
            throw NSError(
                domain: "WebRTCManager", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "DataChannel not found for \(peerID)"])
        }

        guard dc.readyState == .open else {
            throw NSError(
                domain: "WebRTCManager", code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "DataChannel not ready: \(dc.readyState.rawValue)"
                ])
        }

        let buffer = RTCDataBuffer(data: data, isBinary: true)
        let success = dc.sendData(buffer)
        if !success {
            throw NSError(
                domain: "WebRTCManager", code: -2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to send data via DataChannel (buffer full or channel closed)"
                ])
        }
    }

    // MARK: - Helper for Mapping
    // 简单的反向查找 map: PeerConnection -> PeerID
    private var pcToPeerID: [ObjectIdentifier: String] = [:]

    private func register(peerConnection: RTCPeerConnection, for peerID: String) {
        lock.lock()
        defer { lock.unlock() }
        peerConnections[peerID] = peerConnection
        pcToPeerID[ObjectIdentifier(peerConnection)] = peerID
    }

    public func removeConnection(for peerID: String) {
        lock.lock()
        let pc = peerConnections.removeValue(forKey: peerID)
        let dc = dataChannels.removeValue(forKey: peerID)
        if let pc = pc {
            pcToPeerID.removeValue(forKey: ObjectIdentifier(pc))
        }
        lock.unlock()

        dc?.close()
        pc?.close()

        resumeContinuations(for: peerID, result: false)
    }

    private func getPeerID(for peerConnection: RTCPeerConnection) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return pcToPeerID[ObjectIdentifier(peerConnection)]
    }
}

// MARK: - Delegates

extension WebRTCManager: RTCPeerConnectionDelegate {
    public func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState
    ) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
    }

    public func peerConnection(
        _ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream
    ) {}

    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    public func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState
    ) {
        guard let peerID = getPeerID(for: peerConnection) else { return }

        if newState == .failed || newState == .closed {
            AppLogger.syncPrint(
                "[WebRTC] ⚠️ Connection to \(peerID.prefix(8)) failed or closed. State: \(newState.rawValue)"
            )
            self.removeConnection(for: peerID)
        }

        DispatchQueue.main.async {
            self.delegate?.webRTCManager(self, didChangeConnectionState: newState, for: peerID)
        }
    }

    public func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState
    ) {}

    public func peerConnection(
        _ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate
    ) {
        guard let peerID = getPeerID(for: peerConnection) else { return }
        let iceCandidate = IceCandidate(from: candidate)
        DispatchQueue.main.async {
            self.delegate?.webRTCManager(self, didDiscoverLocalCandidate: iceCandidate, for: peerID)
        }
    }

    public func peerConnection(
        _ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]
    ) {}

    public func peerConnection(
        _ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel
    ) {
        guard let peerID = getPeerID(for: peerConnection) else { return }
        print("[WebRTC] DataChannel Received: \(dataChannel.label) from \(peerID)")
        dataChannel.delegate = self
        lock.lock()
        self.dataChannels[peerID] = dataChannel
        lock.unlock()
    }
}

extension WebRTCManager: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        print("[WebRTC] DataChannel State Changed: \(dataChannel.readyState.rawValue)")

        // Find which peer this belongs to
        var peerID: String?
        lock.lock()
        for (pid, dc) in dataChannels {
            if dc === dataChannel {
                peerID = pid
                break
            }
        }
        lock.unlock()

        if let peerID = peerID {
            if dataChannel.readyState == .open {
                resumeContinuations(for: peerID, result: true)
            } else if dataChannel.readyState == .closed || dataChannel.readyState == .closing {
                resumeContinuations(for: peerID, result: false)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.webRTCManager(
                    self, didChangeDataChannelState: dataChannel.readyState, for: peerID)
            }
        }
    }

    public func dataChannel(
        _ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer
    ) {
        // Find which peer this belongs to
        // Note: RTCDataChannel delegate doesn't tell us which PeerConnection it came from easily
        // We'd need to map DataChannel -> PeerID as well if we have many.
        // We'd need to map DataChannel -> PeerID as well if we have many.
        // For now, simpler scan:
        var peerID: String?
        lock.lock()
        for (pid, dc) in dataChannels {
            if dc === dataChannel {
                peerID = pid
                break
            }
        }
        lock.unlock()

        if let peerID = peerID {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.webRTCManager(self, didReceiveData: buffer.data, from: peerID)
            }
        }
    }
}
