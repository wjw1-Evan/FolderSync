import Foundation

public struct VectorClock: Codable, Equatable {
    public var versions: [String: Int] // PeerID: Version
    
    public init(versions: [String: Int] = [:]) {
        self.versions = versions
    }
    
    public mutating func increment(for peerID: String) {
        versions[peerID, default: 0] += 1
    }
    
    public mutating func merge(with other: VectorClock) {
        for (peerID, version) in other.versions {
            versions[peerID] = max(versions[peerID, default: 0], version)
        }
    }
    
    public enum Comparison {
        case antecedent // This happened before the other
        case successor  // This happened after the other
        case concurrent // Conflict!
        case equal
    }
    
    public func compare(to other: VectorClock) -> Comparison {
        var lessThan = false
        var greaterThan = false
        
        let allKeys = Set(versions.keys).union(other.versions.keys)
        
        for key in allKeys {
            let v1 = versions[key, default: 0]
            let v2 = other.versions[key, default: 0]
            
            if v1 < v2 {
                lessThan = true
            } else if v1 > v2 {
                greaterThan = true
            }
        }
        
        if lessThan && greaterThan {
            return .concurrent
        } else if lessThan {
            return .antecedent
        } else if greaterThan {
            return .successor
        } else {
            return .equal
        }
    }
}
