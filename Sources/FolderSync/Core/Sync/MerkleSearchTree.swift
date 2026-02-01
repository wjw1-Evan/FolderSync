import Crypto
import Foundation

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

    /// 递归查找差异：高效对比两棵树，返回差异文件路径列表
    public func findDifferences(other: MerkleSearchTree) -> Set<String> {
        return findDifferences(node1: self.root, node2: other.root)
    }

    private func findDifferences(node1: MSTNode?, node2: MSTNode?) -> Set<String> {
        // 1. 如果两个节点都为空，无差异
        if node1 == nil && node2 == nil { return [] }

        // 2. 如果其中一个为空，返回另一个节点子树下的所有叶子节点（视为新增或删除）
        if node1 == nil {
            return collectLeafKeys(node: node2)
        }
        if node2 == nil {
            return collectLeafKeys(node: node1)
        }

        guard let n1 = node1, let n2 = node2 else { return [] }

        // 3. 如果哈希相同，说明子树完全一致，剪枝
        if n1.computeHash() == n2.computeHash() {
            return []
        }

        // 4. 哈希不同，需要比较当前节点和子节点
        var differences: Set<String> = []

        // 比较当前节点的值 (hash of content)
        // 注意：MSTNode 的 key 是文件名，value 是文件内容的哈希
        // 如果 key 相同但 value 不同，说明文件内容变了
        if n1.key == n2.key {
            if n1.value != n2.value {
                differences.insert(n1.key)
            }
        } else {
            // key 不同，说明结构上有差异，这里简化处理：
            // 在标准 MST 中，节点位置由 key 决定。
            // 简单的递归比较可能需要对齐 children。
            // 由于这里的 MST 实现是简化的（level based insertion），结构可能不完全确定性（取决于插入顺序？不，sorted children helps）。
            // 但如果 key 不同，说明这两个 node 代表不同的 ranges 或 items。
            // 简单策略：如果不匹配，收集两者的 keys（如果它们是叶子或包含内容）
            // 这个简化的 MST 实现比较难以做完美的结构对齐，
            // 所以如果顶层 key 不同，我们将它们视为不同的分支。
            // 但为了准确性，我们最好依赖 collectLeafKeys 如果无法对齐。
        }

        // 尝试对齐子节点进行比较
        // 因为 children 是排过序的，我们可以用双指针法高效比较
        let children1 = n1.children.sorted(by: { $0.key < $1.key })
        let children2 = n2.children.sorted(by: { $0.key < $1.key })

        var i = 0
        var j = 0

        while i < children1.count && j < children2.count {
            let c1 = children1[i]
            let c2 = children2[j]

            if c1.key == c2.key {
                // key 相同，递归比较
                let childDiffs = findDifferences(node1: c1, node2: c2)
                differences.formUnion(childDiffs)
                i += 1
                j += 1
            } else if c1.key < c2.key {
                // c1 有而 c2 没有 -> c1 是差异
                differences.formUnion(collectLeafKeys(node: c1))
                i += 1
            } else {
                // c2 有而 c1 没有 -> c2 是差异
                differences.formUnion(collectLeafKeys(node: c2))
                j += 1
            }
        }

        // 处理剩余的子节点
        while i < children1.count {
            differences.formUnion(collectLeafKeys(node: children1[i]))
            i += 1
        }
        while j < children2.count {
            differences.formUnion(collectLeafKeys(node: children2[j]))
            j += 1
        }

        // 别忘了检查当前节点本身是否是差异（如果 key 不匹配的情况在上面 children 循环中覆盖了？）
        // MSTNode 本身包含 kv。如果 n1 和 n2 key 相同但 value 不同，已处理。
        // 如果 n1 和 n2 key 不同？
        // 在 `insert` 逻辑中，root 可能是其中的一个节点。
        // 如果 root keys 不同，我们其实应该把它们当作 children 比较逻辑来处理吗？
        // 不，findDifferences(node1, node2) 假设我们在比较两个"对应"的位置。
        // 如果 root key 不同，说明整棵树的根都变了。
        // 在这种情况下，上面的 children 比较可能无法正确工作，因为 context 不同。
        // *但是*，我们的 MST 是基于 Key 排序构建的吗？
        // `insert` 逻辑：`if newNode.level > current.level { newNode.children.append(current) ... }`
        // 这意味着 root 总是 level 最高的节点。
        // 如果两个树的 root key 不同，说明最高 level 的节点不同。
        // 这比较复杂。
        // 为了安全起见，回退到：如果 key 不同，直接收集所有（O(N)），
        // 只有当 key 相同能对齐时才递归 (O(log N))。
        // 考虑到大部分同步场景根节点可能相同（或者是虚根），或者我们至少能部分对齐。

        // 5. 如果根 Key 不同，尝试通过 Level 判断包含关系
        if n1.key != n2.key {
            // 情况 A: n1 层级也就低，n1 可能在 n2 的子节点中
            if n1.level < n2.level {
                var diffs: Set<String> = []
                // n2 本身是差异
                if n1.key != n2.key { diffs.insert(n2.key) }

                // 在 n2 的子节点中找 n1
                let children2 = n2.children.sorted(by: { $0.key < $1.key })
                var foundMatch = false
                for c2 in children2 {
                    if c2.key == n1.key || c2.level >= n1.level {
                        // 找到潜在匹配或同级节点 (这里简化假设: key 相同或者是 n1 的祖先/同级)
                        // 但由于 level based MST 只有高 level 指向低 level，c2 level 肯定 < n2.level
                        // 如果 c2.key == n1.key，直接比较
                        // 如果 c2.key != n1.key 但 level 怎么处理？
                        // 简化：只找 key 相同的
                        if c2.key == n1.key {
                            diffs.formUnion(findDifferences(node1: n1, node2: c2))
                            foundMatch = true
                        } else {
                            // 其他子节点都是差异
                            diffs.formUnion(collectLeafKeys(node: c2))
                        }
                    } else {
                        // c2 level < n1.level 且 key 不同，也肯定是差异
                        diffs.formUnion(collectLeafKeys(node: c2))
                    }
                }

                // 如果 n2 的子节点里都没找到 n1，说明 n1 在 n2 树里不存在 (被删除了)
                if !foundMatch {
                    diffs.formUnion(collectLeafKeys(node: n1))
                }
                return diffs
            }

            // 情况 B: n2 层级低，n2 可能在 n1 的子节点中
            if n2.level < n1.level {
                var diffs: Set<String> = []
                // n1 本身是差异
                if n1.key != n2.key { diffs.insert(n1.key) }

                let children1 = n1.children.sorted(by: { $0.key < $1.key })
                var foundMatch = false
                for c1 in children1 {
                    if c1.key == n2.key {
                        diffs.formUnion(findDifferences(node1: c1, node2: n2))
                        foundMatch = true
                    } else {
                        diffs.formUnion(collectLeafKeys(node: c1))
                    }
                }

                if !foundMatch {
                    diffs.formUnion(collectLeafKeys(node: n2))
                }
                return diffs
            }

            // 情况 C: 同级但 Key 不同，完全不匹配
            let all1 = collectLeafKeys(node: n1)
            let all2 = collectLeafKeys(node: n2)
            return all1.union(all2)
        }

        return differences
    }

    private func collectLeafKeys(node: MSTNode?) -> Set<String> {
        guard let node = node else { return [] }
        var keys: Set<String> = []
        // 当前节点也是一个 entry
        keys.insert(node.key)
        for child in node.children {
            keys.formUnion(collectLeafKeys(node: child))
        }
        return keys
    }
}
