import Foundation

public protocol SignalingClientDelegate: AnyObject {
    func signalingClient(
        _ client: SignalingClient, didReceiveRemoteSdp sdp: SessionDescription, from peerID: String)
    func signalingClient(
        _ client: SignalingClient, didReceiveCandidate candidate: IceCandidate, from peerID: String)
    func signalingClientDidConnect(_ client: SignalingClient)
    func signalingClientDidDisconnect(_ client: SignalingClient)
}

public protocol SignalingClient: AnyObject {
    var delegate: SignalingClientDelegate? { get set }
    func connect()
    func disconnect()
    func send(sdp: SessionDescription, to peerID: String)
    func send(candidate: IceCandidate, to peerID: String)
}

// 简单的 LAN Signaling Client 占位符
// 实际在 P2PNode 中，我们会利用 LANDiscovery 现有的广播机制来交换初始信息，
// 或者建立临时的 TCP 连接来交换 SDP。
// 这里先提供一个基础接口。

public class LANSignalingWrapper: SignalingClient {
    public weak var delegate: SignalingClientDelegate?
    private let myPeerID: String

    // 发送回调，由外部（P2PNode）设置实现实际传输
    public var onSendSignal: ((SignalingMessage) -> Void)?

    public init(myPeerID: String) {
        self.myPeerID = myPeerID
    }

    public func connect() {
        // LAN 模式下通常是“即时在线”的
        delegate?.signalingClientDidConnect(self)
    }

    public func disconnect() {
        delegate?.signalingClientDidDisconnect(self)
    }

    public func send(sdp: SessionDescription, to peerID: String) {
        let msg = SignalingMessage(
            type: sdp.type, sdp: sdp, candidate: nil, targetPeerID: peerID, senderPeerID: myPeerID)
        onSendSignal?(msg)
    }

    public func send(candidate: IceCandidate, to peerID: String) {
        let msg = SignalingMessage(
            type: "candidate", sdp: nil, candidate: candidate, targetPeerID: peerID,
            senderPeerID: myPeerID)
        onSendSignal?(msg)
    }

    // 外部接收到消息调用此方法注入
    public func receiveMessage(_ message: SignalingMessage) {
        if let sdp = message.sdp {
            delegate?.signalingClient(self, didReceiveRemoteSdp: sdp, from: message.senderPeerID)
        } else if let candidate = message.candidate {
            delegate?.signalingClient(
                self, didReceiveCandidate: candidate, from: message.senderPeerID)
        }
    }
}
