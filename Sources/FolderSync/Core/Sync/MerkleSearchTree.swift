import Foundation
import Crypto

public class MSTNode {
    public let key: String
    public let value: String
    public let level: Int
    public var children: [MSTNode] = []
    
    public init(key: String, value: String, level: Int) {
        self.key = key
        self.value = value
        self.level = level
    }
    
    public func computeHash() -> String {
        var content = "\(key):\(value):\(level)"
        for child in children.sorted(by: { $0.key < $1.key }) {
            content += child.computeHash()
        }
        let hash = SHA256.hash(data: Data(content.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

public class MerkleSearchTree {
    private var root: MSTNode?
    
    public init() {}
    
    // In a real MST, insertion involves probabilistic level assignment
    // for logarithmic depth. This is a simplified version.
    public func insert(key: String, value: String) {
        let level = calculateLevel(for: key)
        let newNode = MSTNode(key: key, value: value, level: level)
        
        if root == nil {
            root = newNode
            return
        }
        
        // Simplified recursive insertion
        root = insert(newNode, into: root!)
    }
    
    private func insert(_ newNode: MSTNode, into current: MSTNode) -> MSTNode {
        if newNode.level > current.level {
            // New node becomes a parent or high-level pivot
            newNode.children.append(current)
            return newNode
        } else {
            current.children.append(newNode)
            return current
        }
    }
    
    private func calculateLevel(for key: String) -> Int {
        let hash = SHA256.hash(data: Data(key.utf8))
        let firstByte = hash.map { $0 }.first ?? 0
        // Count leading zeros or use some other stable mapping
        return Int(firstByte.leadingZeroBitCount)
    }
    
    public var rootHash: String? {
        root?.computeHash()
    }
    
    public func getAllEntries() -> [String: String] {
        var entries: [String: String] = [:]
        func collect(_ node: MSTNode?) {
            guard let node = node else { return }
            entries[node.key] = node.value
            for child in node.children {
                collect(child)
            }
        }
        collect(root)
        return entries
    }
    
    /// 递归差分：仅在哈希不一致时递归向下探测，返回差异路径列表
    /// TODO: 需要实现完整的递归差分算法，当前使用 getAllEntries 作为简化实现
    public func diff(remoteHash: String, remoteMST: MerkleSearchTree) -> [String] {
        guard let localHash = rootHash, localHash != remoteHash else { return [] }
        // 简化实现：返回所有条目（实际应递归比较子树）
        return Array(getAllEntries().keys)
    }
}
