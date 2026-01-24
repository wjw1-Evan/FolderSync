import Foundation

/// Stores trusted peer IDs (certificate pinning). Only paired/confirmed peers are persisted.
public enum TrustedPeersStore {
    private static let key = "FolderSync.trustedPeers"
    
    public static var peerIDs: Set<String> {
        get {
            (UserDefaults.standard.stringArray(forKey: key) ?? []).reduce(into: Set()) { $0.insert($1) }
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: key)
        }
    }
    
    public static func add(_ peerID: String) {
        var s = peerIDs
        s.insert(peerID)
        peerIDs = s
    }
    
    public static func remove(_ peerID: String) {
        var s = peerIDs
        s.remove(peerID)
        peerIDs = s
    }
    
    public static func contains(_ peerID: String) -> Bool {
        peerIDs.contains(peerID)
    }
    
    /// When pinning is enabled, only trusted peers are used for sync.
    public static var pinningEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "FolderSync.pinningEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "FolderSync.pinningEnabled") }
    }
}
