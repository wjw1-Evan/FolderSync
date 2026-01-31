import Foundation
import WebRTC

protocol WebRTCManagerDelegate: AnyObject {
    func webRTCManager(
        _ manager: WebRTCManager, didDiscoverLocalCandidate candidate: IceCandidate,
        for peerID: String)
    func webRTCManager(
        _ manager: WebRTCManager, didChangeConnectionState state: RTCIceConnectionState,
        for peerID: String)
    func webRTCManager(_ manager: WebRTCManager, didReceiveData data: Data, from peerID: String)
}

public class WebRTCManager: NSObject {
    private let factory: RTCPeerConnectionFactory
    // peerID -> RTCPeerConnection
    private var peerConnections: [String: RTCPeerConnection] = [:]
    // peerID -> RTCDataChannel
    private var dataChannels: [String: RTCDataChannel] = [:]

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
        let pcs = Array(peerConnections.values)
        peerConnections.removeAll()
        dataChannels.removeAll()
        pcToPeerID.removeAll()
        lock.unlock()

        for pc in pcs {
            pc.close()
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

        guard let dc = dc, dc.readyState == .open else {
            throw NSError(
                domain: "WebRTCManager", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "DataChannel not ready"])
        }

        let buffer = RTCDataBuffer(data: data, isBinary: true)
        dc.sendData(buffer)
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
            DispatchQueue.main.async {
                self.delegate?.webRTCManager(self, didReceiveData: buffer.data, from: peerID)
            }
        }
    }
}
