import Crypto
import Foundation

public class MSTNode {
    public let key: String
    public let value: String
    public let priority: [UInt8]
    public var left: MSTNode?
    public var right: MSTNode?

    public init(key: String, value: String, priority: [UInt8]? = nil) {
        self.key = key
        self.value = value
        if let p = priority {
            self.priority = p
        } else {
            let hash = SHA256.hash(data: Data(key.utf8))
            self.priority = hash.map { $0 }
        }
    }

    public func computeHash() -> String {
        var content = "node:\(key):\(value)"
        if let leftHash = left?.computeHash() {
            content += "L:\(leftHash)"
        }
        if let rightHash = right?.computeHash() {
            content += "R:\(rightHash)"
        }
        let hash = SHA256.hash(data: Data(content.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    static func isHigherPriority(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        for (byteA, byteB) in zip(a, b) {
            if byteA > byteB { return true }
            if byteA < byteB { return false }
        }
        return a.count > b.count
    }
}

public class MerkleSearchTree {
    private var root: MSTNode?

    public init() {}

    public func insert(key: String, value: String) {
        root = _insert(root, key: key, value: value)
    }

    private func _insert(_ node: MSTNode?, key: String, value: String) -> MSTNode {
        guard let current = node else {
            return MSTNode(key: key, value: value)
        }

        if key < current.key {
            current.left = _insert(current.left, key: key, value: value)
            if let left = current.left, MSTNode.isHigherPriority(left.priority, current.priority) {
                return rotateRight(current)
            }
        } else if key > current.key {
            current.right = _insert(current.right, key: key, value: value)
            if let right = current.right, MSTNode.isHigherPriority(right.priority, current.priority)
            {
                return rotateLeft(current)
            }
        } else {
            let newNode = MSTNode(key: key, value: value, priority: current.priority)
            newNode.left = current.left
            newNode.right = current.right
            return newNode
        }
        return current
    }

    private func rotateRight(_ y: MSTNode) -> MSTNode {
        guard let x = y.left else { return y }
        y.left = x.right
        x.right = y
        return x
    }

    private func rotateLeft(_ x: MSTNode) -> MSTNode {
        guard let y = x.right else { return x }
        x.right = y.left
        y.left = x
        return y
    }

    public var rootHash: String? {
        root?.computeHash()
    }

    public func getAllEntries() -> [String: String] {
        var entries: [String: String] = [:]
        func collect(_ node: MSTNode?) {
            guard let node = node else { return }
            entries[node.key] = node.value
            collect(node.left)
            collect(node.right)
        }
        collect(root)
        return entries
    }

    public func findDifferences(other: MerkleSearchTree) -> Set<String> {
        var diffs: Set<String> = []
        _findDifferences(node1: self.root, node2: other.root, diffs: &diffs)
        return diffs
    }

    private func _findDifferences(node1: MSTNode?, node2: MSTNode?, diffs: inout Set<String>) {
        if node1 == nil && node2 == nil { return }

        // Pruning: if hashes match, entire subtrees are identical
        if node1?.computeHash() == node2?.computeHash() {
            return
        }

        guard let n1 = node1 else {
            collectKeys(node: node2, into: &diffs)
            return
        }

        // Search for n1.key in tree2
        let (l2, mid2, r2) = _split(node2, key: n1.key)

        if n1.value != mid2?.value {
            diffs.insert(n1.key)
        }

        _findDifferences(node1: n1.left, node2: l2, diffs: &diffs)
        _findDifferences(node1: n1.right, node2: r2, diffs: &diffs)
    }

    /// Non-destructive split
    private func _split(_ node: MSTNode?, key: String) -> (MSTNode?, MSTNode?, MSTNode?) {
        guard let current = node else { return (nil, nil, nil) }

        if key < current.key {
            let (l, mid, r) = _split(current.left, key: key)
            let newNode = MSTNode(
                key: current.key, value: current.value, priority: current.priority)
            newNode.left = r
            newNode.right = current.right
            return (l, mid, newNode)
        } else if key > current.key {
            let (l, mid, r) = _split(current.right, key: key)
            let newNode = MSTNode(
                key: current.key, value: current.value, priority: current.priority)
            newNode.left = current.left
            newNode.right = l
            return (newNode, mid, r)
        } else {
            return (current.left, current, current.right)
        }
    }

    private func collectKeys(node: MSTNode?, into keys: inout Set<String>) {
        guard let node = node else { return }
        keys.insert(node.key)
        collectKeys(node: node.left, into: &keys)
        collectKeys(node: node.right, into: &keys)
    }
}
