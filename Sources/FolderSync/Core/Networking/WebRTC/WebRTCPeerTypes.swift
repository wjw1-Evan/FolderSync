import Foundation
import WebRTC

/// 简单的 SDP 封装，用于信令传输
public struct SessionDescription: Codable {
    public let sdp: String
    public let type: String  // "offer" | "answer" | "pranswer" | "rollback"

    public init(from rtcSdp: RTCSessionDescription) {
        self.sdp = rtcSdp.sdp
        switch rtcSdp.type {
        case .offer: self.type = "offer"
        case .answer: self.type = "answer"
        case .prAnswer: self.type = "pranswer"
        case .rollback: self.type = "rollback"
        @unknown default: self.type = "unknown"
        }
    }

    public var rtcSessionDescription: RTCSessionDescription {
        let typeVal: RTCSdpType
        switch type {
        case "offer": typeVal = .offer
        case "answer": typeVal = .answer
        case "pranswer": typeVal = .prAnswer
        case "rollback": typeVal = .rollback
        default: typeVal = .offer  // Fallback
        }
        return RTCSessionDescription(type: typeVal, sdp: sdp)
    }
}

/// ICE Candidate 封装
public struct IceCandidate: Codable {
    public let sdp: String
    public let sdpMLineIndex: Int32
    public let sdpMid: String?

    public init(from rtcCandidate: RTCIceCandidate) {
        self.sdp = rtcCandidate.sdp
        self.sdpMLineIndex = rtcCandidate.sdpMLineIndex
        self.sdpMid = rtcCandidate.sdpMid
    }

    public var rtcIceCandidate: RTCIceCandidate {
        return RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
    }
}

/// 信令消息结构
public struct SignalingMessage: Codable {
    public let type: String  // "offer", "answer", "candidate", "bye"
    public let sdp: SessionDescription?
    public let candidate: IceCandidate?
    public let targetPeerID: String?  // 目标 PeerID，如果为 nil 则广播
    public let senderPeerID: String  // 发送者 PeerID
}
