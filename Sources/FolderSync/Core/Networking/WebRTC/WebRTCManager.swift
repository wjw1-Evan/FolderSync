import Foundation
@preconcurrency import WebRTC

@MainActor
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

@MainActor
public class WebRTCManager: NSObject {
    private let factory: RTCPeerConnectionFactory
    // peerID -> RTCPeerConnection
    private var peerConnections: [String: RTCPeerConnection] = [:]
    // peerID -> RTCDataChannel
    private var dataChannels: [String: RTCDataChannel] = [:]

    // For reassembling incoming chunks: peerID -> [messageID: [index: data]]
    private var chunkBuffers: [String: [String: [Int: Data]]] = [:]
    // For tracking total chunks: peerID -> [messageID: totalCount]
    private var chunkTotals: [String: [String: Int]] = [:]

    private let maxChunkSize = 64 * 1024  // 64KB
    // Waiter class to allow reference comparison for CheckedContinuation
    // 包含线程安全的 resume 逻辑，确保 continuation 只被 resume 一次
    private class Waiter {
        let continuation: CheckedContinuation<Bool, Never>
        private var _hasResumed = false

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        /// 尝试 resume continuation，如果已经 resumed 则返回 false
        /// 这是线程安全的
        func tryResume(returning result: Bool) -> Bool {
            if _hasResumed {
                return false
            }
            _hasResumed = true
            continuation.resume(returning: result)
            return true
        }

        var hasResumed: Bool {
            return _hasResumed
        }
    }
    // peerID -> Continuations waiting for connection
    private var pendingReadyContinuations: [String: [Waiter]] = [:]

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
        // Cannot call @MainActor method synchronously in deinit.
        // The cleanup will happen when the object is deallocated, but we can't
        // guarantee stop() runs before deallocation completes.
        // This is acceptable since WebRTC handles its own cleanup.
    }

    public func stop() {
        let pcValues = Array(peerConnections.values)
        let dcValues = Array(dataChannels.values)
        let peerIDs = Array(peerConnections.keys)
        peerConnections.removeAll()
        dataChannels.removeAll()
        pcToPeerID.removeAll()

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
        return peerConnections[peerID] != nil
    }

    public func getPeerConnection(for peerID: String) -> RTCPeerConnection? {
        return peerConnections[peerID]
    }

    /// 检查 DataChannel 是否就绪（已打开）
    public func isDataChannelReady(for peerID: String) -> Bool {
        guard let dc = dataChannels[peerID] else { return false }
        return dc.readyState == .open
    }

    /// 等待 DataChannel 就绪，带超时
    /// 使用主动轮询 + 事件驱动的混合策略，确保不会错过状态变更
    public func waitForDataChannelReady(for peerID: String, timeout: TimeInterval = 30.0) async
        -> Bool
    {
        let startTime = Date()

        // 1. 立即检查
        if isDataChannelReady(for: peerID) {
            // 已就绪，不再打印日志以减少大量点对点传输时的日志量
            return true
        }

        // 2. 检查是否有对应的 PeerConnection
        let pc = peerConnections[peerID]
        if pc == nil {
            AppLogger.syncPrint(
                "[WebRTC] ❌ Cannot wait for DataChannel: No PeerConnection for \(peerID.prefix(8))"
            )
            return false
        }

        let initialState = pc?.iceConnectionState
        if let state = initialState, state == .failed || state == .closed {
            AppLogger.syncPrint(
                "[WebRTC] ❌ Cannot wait for DataChannel: Connection to \(peerID.prefix(8)) already in state \(state.rawValue)"
            )
            return false
        }

        AppLogger.syncPrint(
            "[WebRTC] ⏳ Waiting for DataChannel to \(peerID.prefix(8)), ICE state: \(initialState?.rawValue ?? -1)"
        )

        // 3. 使用 withCheckedContinuation 并在 Task { @MainActor } 中处理逻辑
        return await withCheckedContinuation { continuation in
            let waiter = Waiter(continuation)
            Task { @MainActor in
                self.handleWaitingForDataChannel(
                    waiter: waiter, peerID: peerID, timeout: timeout, startTime: startTime)
            }
        }
    }

    @MainActor
    private func handleWaitingForDataChannel(
        waiter: Waiter, peerID: String, timeout: TimeInterval, startTime: Date
    ) {
        let pollInterval: TimeInterval = 0.5

        // 安全的 resume 辅助函数
        func safeResume(result: Bool, reason: String) {
            // 从等待列表中移除
            self.unregisterWaiter(waiter, for: peerID)

            // 尝试 resume
            if waiter.tryResume(returning: result) {
                let elapsed = Date().timeIntervalSince(startTime)
                AppLogger.syncPrint(
                    "[WebRTC] \(result ? "✅" : "❌") DataChannel wait \(reason) for \(peerID.prefix(8)) after \(String(format: "%.1f", elapsed))s"
                )
            }
        }

        // 立即再次检查就绪状态
        if self.isDataChannelReady(for: peerID) {
            safeResume(result: true, reason: "already open (rechecked)")
            return
        }

        // 检查连接是否已经失败
        let pc = peerConnections[peerID]
        if pc == nil || pc?.iceConnectionState == .failed || pc?.iceConnectionState == .closed {
            safeResume(result: false, reason: "connection failed or removed")
            return
        }

        // 注册到等待列表
        self.registerWaiter(waiter, for: peerID)

        // 启动主动轮询任务
        Task {
            var pollCount = 0
            let maxPolls = Int(timeout / pollInterval)

            while pollCount < maxPolls {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                pollCount += 1

                // 检查是否已经被其他逻辑处理（如事件回调）
                if waiter.hasResumed { return }

                // 回到 MainActor 检查状态
                await MainActor.run {
                    if self.isDataChannelReady(for: peerID) {
                        safeResume(result: true, reason: "ready (polled)")
                        return
                    }

                    let currentPC = self.peerConnections[peerID]
                    let currentState = currentPC?.iceConnectionState

                    if currentPC == nil {
                        safeResume(result: false, reason: "PeerConnection removed")
                        return
                    }

                    if let state = currentState, state == .failed || state == .closed {
                        safeResume(result: false, reason: "ICE state \(state.rawValue)")
                        return
                    }

                    if pollCount % 10 == 0 {
                        let dcState = self.dataChannels[peerID]?.readyState.rawValue ?? -1
                        AppLogger.syncPrint(
                            "[WebRTC] ⏳ Still waiting for DataChannel to \(peerID.prefix(8)): ICE=\(currentState?.rawValue ?? -1), DC=\(dcState)"
                        )
                    }
                }

                if waiter.hasResumed { return }
            }

            // 超时
            await MainActor.run {
                safeResume(result: false, reason: "timeout")
            }
        }
    }

    private func registerWaiter(_ waiter: Waiter, for peerID: String) {
        var list = pendingReadyContinuations[peerID] ?? []
        list.append(waiter)
        pendingReadyContinuations[peerID] = list
    }

    private func unregisterWaiter(_ waiter: Waiter, for peerID: String) {
        guard var list = pendingReadyContinuations[peerID], !list.isEmpty else { return }
        if let index = list.firstIndex(where: { $0 === waiter }) {
            list.remove(at: index)
            pendingReadyContinuations[peerID] = list
        }
    }

    private func resumeContinuations(for peerID: String, result: Bool, onlyOne: Bool = false) {
        guard var list = pendingReadyContinuations[peerID], !list.isEmpty else {
            return
        }

        if onlyOne {
            let first = list.removeFirst()
            pendingReadyContinuations[peerID] = list
            // 使用 tryResume 确保只 resume 一次
            _ = first.tryResume(returning: result)
        } else {
            pendingReadyContinuations[peerID] = []
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
            self.dataChannels[peerID] = dc
        }

        peerConnection.offer(for: constraints) { sdp, error in
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
        var peerConnection = peerConnections[peerID]

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
                pc.answer(for: constraints) { (sdp: RTCSessionDescription?, error: Error?) in
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
        let pc = peerConnections[peerID]

        guard let pc = pc else { return }
        pc.add(candidate.rtcIceCandidate) { _ in }
    }

    func sendData(_ data: Data, to peerID: String) async throws {
        let dc = dataChannels[peerID]

        guard let dc = dc else {
            throw NSError(
                domain: "WebRTCManager", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "DataChannel not found for \(peerID)"])
        }

        if data.count <= maxChunkSize {
            // Send as a single complete message
            var packet = Data([0])  // Type 0: Full message
            packet.append(data)
            try await sendRawData(packet, to: dc, peerID: peerID)
        } else {
            // Send in chunks
            let messageID = UUID().uuidString
            let totalChunks = Int(ceil(Double(data.count) / Double(maxChunkSize)))

            AppLogger.syncPrint(
                "[WebRTC] 📤 Sending large message to \(peerID.prefix(8)): \(data.count / 1024) KB, \(totalChunks) chunks"
            )

            // 使用 Task.detached 避免在 MainActor 上执行耗时的分块和流量控制循环
            try await Task.detached(priority: .medium) { [weak self] in
                guard let self = self else { return }

                for i in 0..<totalChunks {
                    // 再次检查通道状态
                    let readyState = await MainActor.run { dc.readyState }
                    guard readyState == .open else {
                        throw NSError(
                            domain: "WebRTCManager", code: -1,
                            userInfo: [
                                NSLocalizedDescriptionKey: "DataChannel closed during transfer"
                            ])
                    }

                    let start = i * self.maxChunkSize
                    let end = min(start + self.maxChunkSize, data.count)
                    let chunkData = data.subdata(in: start..<end)

                    var packet = Data([1])  // Type 1: Chunk
                    if let idData = messageID.data(using: .utf8) {
                        let idLen = UInt8(idData.count)
                        packet.append(Data([idLen]))
                        packet.append(idData)
                    }

                    var index = Int32(i).bigEndian
                    var total = Int32(totalChunks).bigEndian
                    packet.append(Data(bytes: &index, count: MemoryLayout<Int32>.size))
                    packet.append(Data(bytes: &total, count: MemoryLayout<Int32>.size))
                    packet.append(chunkData)

                    try await self.sendRawData(packet, to: dc, peerID: peerID)
                }
            }.value
        }
    }

    private func sendRawData(_ data: Data, to dc: RTCDataChannel, peerID: String) async throws {
        guard dc.readyState == .open else {
            throw NSError(
                domain: "WebRTCManager", code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "DataChannel not ready: \(dc.readyState.rawValue)"
                ])
        }

        // Flow control: If buffer is too full (> 1MB), wait until it's sent
        // For chunks, we allow a bit more buffer but still wait
        var waitCount = 0
        while dc.bufferedAmount > 1024 * 1024 {
            try await Task.sleep(nanoseconds: 50 * 1_000_000)  // 50ms
            waitCount += 1
            if waitCount > 200 {  // 10s timeout for flow control
                AppLogger.syncPrint(
                    "[WebRTC] ⚠️ Flow control timeout, buffer still full (\(dc.bufferedAmount) bytes) for \(peerID.prefix(8))"
                )
                break
            }
            // Check state again during wait
            if dc.readyState != .open {
                throw NSError(
                    domain: "WebRTCManager", code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "DataChannel closed during wait: \(dc.readyState.rawValue)"
                    ])
            }
        }

        let buffer = RTCDataBuffer(data: data, isBinary: true)
        let success = dc.sendData(buffer)
        if !success {
            AppLogger.syncPrint(
                "[WebRTC] ❌ Failed to send \(data.count) bytes to \(peerID.prefix(8)). State: \(dc.readyState.rawValue), Buffered: \(dc.bufferedAmount)"
            )
            throw NSError(
                domain: "WebRTCManager", code: -2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to send raw data via DataChannel. Size: \(data.count)"
                ])
        }
    }

    // MARK: - Helper for Mapping
    // 简单的反向查找 map: PeerConnection -> PeerID
    private var pcToPeerID: [ObjectIdentifier: String] = [:]

    private func register(peerConnection: RTCPeerConnection, for peerID: String) {
        peerConnections[peerID] = peerConnection
        pcToPeerID[ObjectIdentifier(peerConnection)] = peerID
    }

    public func removeConnection(for peerID: String) {
        let pc = peerConnections.removeValue(forKey: peerID)
        let dc = dataChannels.removeValue(forKey: peerID)
        if let pc = pc {
            pcToPeerID.removeValue(forKey: ObjectIdentifier(pc))
        }

        dc?.close()
        pc?.close()

        chunkBuffers.removeValue(forKey: peerID)
        chunkTotals.removeValue(forKey: peerID)

        resumeContinuations(for: peerID, result: false)
    }

    private func getPeerID(for peerConnection: RTCPeerConnection) -> String? {
        return pcToPeerID[ObjectIdentifier(peerConnection)]
    }
}

// MARK: - Delegates

extension WebRTCManager: @preconcurrency RTCPeerConnectionDelegate {
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
        self.dataChannels[peerID] = dataChannel

        // 如果收到时已经是 open 状态，立即通知等待者
        if dataChannel.readyState == .open {
            resumeContinuations(for: peerID, result: true)
        }
    }
}

extension WebRTCManager: @preconcurrency RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        // Find which peer this belongs to
        var currentPeerID: String?
        for (pid, dc) in dataChannels {
            if dc === dataChannel {
                currentPeerID = pid
                break
            }
        }

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
        for (pid, dc) in dataChannels {
            if dc === dataChannel {
                peerID = pid
                break
            }
        }

        if let peerID = peerID {
            handleReceivedRawData(buffer.data, from: peerID)
        }
    }

    private func handleReceivedRawData(_ data: Data, from peerID: String) {
        guard !data.isEmpty else { return }

        let type = data[0]
        if type == 0 {
            // Full message
            let payload = data.subdata(in: 1..<data.count)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.webRTCManager(self, didReceiveData: payload, from: peerID)
            }
        } else if type == 1 {
            // Chunked message
            var offset = 1
            guard data.count > offset + 1 else { return }

            let idLen = Int(data[offset])
            offset += 1
            guard data.count > offset + idLen + 8 else { return }

            let idData = data.subdata(in: offset..<offset + idLen)
            guard let messageID = String(data: idData, encoding: .utf8) else { return }
            offset += idLen

            let indexData = data.subdata(in: offset..<offset + 4)
            let index = Int(Int32(bigEndian: indexData.withUnsafeBytes { $0.load(as: Int32.self) }))
            offset += 4

            let totalData = data.subdata(in: offset..<offset + 4)
            let total = Int(Int32(bigEndian: totalData.withUnsafeBytes { $0.load(as: Int32.self) }))
            offset += 4

            let chunkData = data.subdata(in: offset..<data.count)

            // Store chunk
            var peerBuffers = chunkBuffers[peerID] ?? [:]
            var msgBuffers = peerBuffers[messageID] ?? [:]
            msgBuffers[index] = chunkData
            peerBuffers[messageID] = msgBuffers
            chunkBuffers[peerID] = peerBuffers

            var peerTotals = chunkTotals[peerID] ?? [:]
            peerTotals[messageID] = total
            chunkTotals[peerID] = peerTotals

            // Check if complete
            if msgBuffers.count == total {
                // Reassemble
                var fullData = Data()
                for i in 0..<total {
                    if let part = msgBuffers[i] {
                        fullData.append(part)
                    } else {
                        // Missing chunk?! Should not happen with reliable ordered channel
                        AppLogger.syncPrint(
                            "[WebRTC] ❌ Missing chunk \(i) for message \(messageID)")
                        return
                    }
                }

                // Cleanup
                chunkBuffers[peerID]?[messageID] = nil
                chunkTotals[peerID]?[messageID] = nil

                // Deliver
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.webRTCManager(self, didReceiveData: fullData, from: peerID)
                }
            }
        }
    }
}
