import Foundation

public final class PairingManager: ObservableObject {
    public static let shared = PairingManager()
    
    public enum PairingState {
        case idle
        case awaitingConfirmation(peerID: String, sasCode: String)
        case paired(peerID: String)
        case rejected(peerID: String)
    }
    
    @Published public private(set) var currentState: PairingState = .idle
    @Published public var pendingPeers: [(peerID: String, sasCode: String)] = []
    
    private init() {}
    
    /// Generate a 6-digit SAS code (Short Authentication String) for out-of-band verification.
    public static func generateSASCode() -> String {
        String(format: "%06d", UInt32.random(in: 0..<1_000_000))
    }
    
    /// Start pairing with a peer; returns SAS code for user verification.
    public func startPairing(peerID: String) -> String {
        let sas = Self.generateSASCode()
        currentState = .awaitingConfirmation(peerID: peerID, sasCode: sas)
        if !pendingPeers.contains(where: { $0.peerID == peerID }) {
            pendingPeers.append((peerID, sas))
        }
        return sas
    }
    
    /// Confirm pairing (user verified SAS matches on both devices).
    public func confirmPairing() {
        if case .awaitingConfirmation(let pid, _) = currentState {
            pendingPeers.removeAll { $0.peerID == pid }
            TrustedPeersStore.add(pid)
        }
        currentState = .idle
    }
    
    /// Reject pairing.
    public func rejectPairing() {
        if case .awaitingConfirmation(let pid, _) = currentState {
            currentState = .rejected(peerID: pid)
            pendingPeers.removeAll { $0.peerID == pid }
        }
        currentState = .idle
    }
    
    public func reset() {
        currentState = .idle
        pendingPeers.removeAll()
    }
}
