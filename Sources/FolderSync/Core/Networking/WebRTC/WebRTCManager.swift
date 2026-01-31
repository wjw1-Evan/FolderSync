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
    // 包含线程安全的 resume 逻辑，确保 continuation 只被 resume 一次
    private class Waiter {
        let continuation: CheckedContinuation<Bool, Never>
        private var _hasResumed = false
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        /// 尝试 resume continuation，如果已经 resumed 则返回 false
        /// 这是线程安全的
        func tryResume(returning result: Bool) -> Bool {
            lock.lock()
            if _hasResumed {
                lock.unlock()
                return false
            }
            _hasResumed = true
            lock.unlock()
            continuation.resume(returning: result)
            return true
        }

        var hasResumed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _hasResumed
        }
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

    public func getPeerConnection(for peerID: String) -> RTCPeerConnection? {
        lock.lock()
        defer { lock.unlock() }
        return peerConnections[peerID]
    }

    /// 检查 DataChannel 是否就绪（已打开）
    public func isDataChannelReady(for peerID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let dc = dataChannels[peerID] else { return false }
        return dc.readyState == .open
    }

    /// 等待 DataChannel 就绪，带超时
    /// 使用主动轮询 + 事件驱动的混合策略，确保不会错过状态变更
    public func waitForDataChannelReady(for peerID: String, timeout: TimeInterval = 30.0) async
        -> Bool
    {
        let startTime = Date()
        let pollInterval: TimeInterval = 0.5  // 每 500ms 主动检查一次

        // 1. 立即检查
        if isDataChannelReady(for: peerID) {
            AppLogger.syncPrint("[WebRTC] ✅ DataChannel already ready for \(peerID.prefix(8))")
            return true
        }

        // 2. 检查是否有对应的 PeerConnection
        lock.lock()
        let pc = peerConnections[peerID]
        let initialState = pc?.iceConnectionState
        lock.unlock()

        if pc == nil {
            AppLogger.syncPrint(
                "[WebRTC] ❌ Cannot wait for DataChannel: No PeerConnection for \(peerID.prefix(8))"
            )
            return false
        }

        if let state = initialState, state == .failed || state == .closed {
            AppLogger.syncPrint(
                "[WebRTC] ❌ Cannot wait for DataChannel: Connection to \(peerID.prefix(8)) already in state \(state.rawValue)"
            )
            return false
        }

        AppLogger.syncPrint(
            "[WebRTC] ⏳ Waiting for DataChannel to \(peerID.prefix(8)), ICE state: \(initialState?.rawValue ?? -1)"
        )

        // 3. 使用主动轮询 + 事件驱动的混合策略
        return await withCheckedContinuation { continuation in
            let waiter = Waiter(continuation)

            // 安全的 resume 辅助函数，使用 Waiter.tryResume() 确保只 resume 一次
            func safeResume(result: Bool, reason: String) {
                // 从等待列表中移除（无论是否成功 resume）
                self.lock.lock()
                if var currentList = self.pendingReadyContinuations[peerID],
                    let index = currentList.firstIndex(where: { $0 === waiter })
                {
                    currentList.remove(at: index)
                    self.pendingReadyContinuations[peerID] = currentList
                }
                self.lock.unlock()

                // 尝试 resume，如果已经被 resume 过则返回 false
                if waiter.tryResume(returning: result) {
                    let elapsed = Date().timeIntervalSince(startTime)
                    AppLogger.syncPrint(
                        "[WebRTC] \(result ? "✅" : "❌") DataChannel wait \(reason) for \(peerID.prefix(8)) after \(String(format: "%.1f", elapsed))s"
                    )
                }
            }

            // 添加到等待列表（用于事件驱动的通知）
            lock.lock()
            // 再次检查就绪状态（在锁内检查以避免竞态）
            if let dc = dataChannels[peerID], dc.readyState == .open {
                lock.unlock()
                safeResume(result: true, reason: "already open (rechecked)")
                return
            }

            var list = pendingReadyContinuations[peerID] ?? []
            list.append(waiter)
            pendingReadyContinuations[peerID] = list
            lock.unlock()

            // 启动主动轮询任务
            Task {
                var pollCount = 0
                let maxPolls = Int(timeout / pollInterval)

                while pollCount < maxPolls {
                    try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                    pollCount += 1

                    // 检查是否已经被事件驱动的逻辑处理
                    if waiter.hasResumed {
                        return
                    }

                    // 主动检查 DataChannel 状态
                    if self.isDataChannelReady(for: peerID) {
                        safeResume(result: true, reason: "ready (polled)")
                        return
                    }

                    // 检查 ICE 连接状态
                    self.lock.lock()
                    let currentPC = self.peerConnections[peerID]
                    let currentState = currentPC?.iceConnectionState
                    let dcState = self.dataChannels[peerID]?.readyState
                    self.lock.unlock()

                    // 如果 PeerConnection 已被移除，终止等待
                    if currentPC == nil {
                        safeResume(result: false, reason: "PeerConnection removed")
                        return
                    }

                    // 如果 ICE 连接失败或关闭，终止等待
                    if let state = currentState, state == .failed || state == .closed {
                        safeResume(result: false, reason: "ICE state \(state.rawValue)")
                        return
                    }

                    // 每 5 次轮询输出一次状态日志
                    if pollCount % 5 == 0 {
                        let sigState = currentPC?.signalingState.rawValue ?? -1
                        AppLogger.syncPrint(
                            "[WebRTC] ⏳ Still waiting for DataChannel to \(peerID.prefix(8)): ICE=\(currentState?.rawValue ?? -1), Sig=\(sigState), DC=\(dcState?.rawValue ?? -1)"
                        )
                    }
                }

                // 超时
                safeResume(result: false, reason: "timeout")
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
            // 使用 tryResume 确保只 resume 一次
            _ = first.tryResume(returning: result)
        } else {
            pendingReadyContinuations[peerID] = []
            lock.unlock()
            for waiter in list {
                // 使用 tryResume 确保只 resume 一次
                _ = waiter.tryResume(returning: result)
            }
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
                AppLogger.syncPrint(
                    "[WebRTC] ❌ Set Remote Description Error for \(peerID.prefix(8)): \(error.localizedDescription)"
                )
                return
            }
            AppLogger.syncPrint("[WebRTC] ✅ Set Remote Description Success for \(peerID.prefix(8))")

            // 如果是 Offer，则创建 Answer
            if rtcSdp.type == .offer {
                let constraints = RTCMediaConstraints(
                    mandatoryConstraints: nil, optionalConstraints: nil)
                pc.answer(for: constraints) {
                    [weak self] (sdp: RTCSessionDescription?, error: Error?) in
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

    func sendData(_ data: Data, to peerID: String) async throws {
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

        // Flow control: If buffer is too full (> 2MB), wait until it's sent
        var waitCount = 0
        while dc.bufferedAmount > 2 * 1024 * 1024 {
            try await Task.sleep(nanoseconds: 100 * 1_000_000)  // 100ms
            waitCount += 1
            if waitCount > 100 {  // 10s timeout for flow control
                AppLogger.syncPrint(
                    "[WebRTC] ⚠️ Flow control timeout, buffer still full for \(peerID.prefix(8))")
                break
            }
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
        AppLogger.syncPrint(
            "[WebRTC] 📥 DataChannel Received: \(dataChannel.label) from \(peerID.prefix(8)), state: \(dataChannel.readyState.rawValue)"
        )
        dataChannel.delegate = self
        lock.lock()
        self.dataChannels[peerID] = dataChannel
        lock.unlock()

        // 如果收到时已经是 open 状态，立即通知等待者
        if dataChannel.readyState == .open {
            resumeContinuations(for: peerID, result: true)
        }
    }
}

extension WebRTCManager: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        // Find which peer this belongs to
        var currentPeerID: String?
        lock.lock()
        for (pid, dc) in dataChannels {
            if dc === dataChannel {
                currentPeerID = pid
                break
            }
        }
        lock.unlock()

        let peerLabel = currentPeerID?.prefix(8) ?? "unknown"
        AppLogger.syncPrint(
            "[WebRTC] 📶 DataChannel (\(peerLabel)) State Changed: \(dataChannel.readyState.rawValue)"
        )

        if let peerID = currentPeerID {
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
