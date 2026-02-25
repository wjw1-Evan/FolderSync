import Crypto
import XCTest

@testable import FolderSync

// MARK: - Advanced Unit Tests for Core Algorithms
//
// 覆盖 README §二 核心技术模块中描述的核心算法：
//   • VectorClock  —— increment / merge / compare 的正确性
//   • MerkleSearchTree —— 确定性哈希、差分定位
//   • FastCDC —— 空文件、小文件、大文件分块边界

final class AdvancedLogicTests: XCTestCase {

    // MARK: - VectorClock: increment & merge

    func testVectorClock_Increment_IsDeterministic() {
        var vc = VectorClock()
        vc.increment(for: "A")
        vc.increment(for: "A")
        vc.increment(for: "B")
        XCTAssertEqual(vc.versions["A"], 2)
        XCTAssertEqual(vc.versions["B"], 1)
    }

    func testVectorClock_Merge_TakesMax() {
        var vc1 = VectorClock(versions: ["A": 3, "B": 1])
        let vc2 = VectorClock(versions: ["A": 1, "B": 5, "C": 2])
        vc1.merge(with: vc2)
        XCTAssertEqual(vc1.versions["A"], 3)  // local max wins
        XCTAssertEqual(vc1.versions["B"], 5)  // remote max wins
        XCTAssertEqual(vc1.versions["C"], 2)  // new peer added
    }

    func testVectorClock_Merge_IsCommutative() {
        let base = VectorClock(versions: ["A": 2, "B": 3])
        let upd = VectorClock(versions: ["A": 4, "C": 1])

        var m1 = base
        m1.merge(with: upd)
        var m2 = upd
        m2.merge(with: base)

        XCTAssertEqual(m1.versions, m2.versions, "merge must be commutative")
    }

    // MARK: - VectorClock: complex comparison

    func testVectorClock_Compare_AllCases() {
        let vc1 = VectorClock(versions: ["A": 1, "B": 2])
        let vc2 = VectorClock(versions: ["A": 1, "B": 2])
        XCTAssertEqual(vc1.compare(to: vc2), .equal)

        let vc3 = VectorClock(versions: ["A": 2, "B": 2])
        XCTAssertEqual(vc3.compare(to: vc1), .successor)
        XCTAssertEqual(vc1.compare(to: vc3), .antecedent)

        let vc4 = VectorClock(versions: ["A": 1, "B": 2, "C": 1])
        XCTAssertEqual(vc4.compare(to: vc1), .successor, "extra peer key means successor")

        let vc5 = VectorClock(versions: ["A": 2, "B": 1])
        XCTAssertEqual(vc5.compare(to: vc1), .concurrent)
    }

    func testVectorClock_ManyPeers_ScalesCorrectly() {
        var vc1 = VectorClock()
        var vc2 = VectorClock()
        for i in 0..<200 {
            vc1.versions["peer_\(i)"] = 10
            vc2.versions["peer_\(i)"] = 10
        }
        XCTAssertEqual(vc1.compare(to: vc2), .equal)
        vc1.increment(for: "peer_100")
        XCTAssertEqual(vc1.compare(to: vc2), .successor)
        vc2.increment(for: "peer_50")
        XCTAssertEqual(vc1.compare(to: vc2), .concurrent)
    }

    // MARK: - MerkleSearchTree: determinism

    func testMST_InsertsAreDeterministic_SmallSet() {
        let entries = [("a.txt", "h1"), ("b.txt", "h2"), ("c.txt", "h3")]
        let mst1 = MerkleSearchTree()
        let mst2 = MerkleSearchTree()
        for (k, v) in entries { mst1.insert(key: k, value: v) }
        for (k, v) in entries.reversed() { mst2.insert(key: k, value: v) }
        XCTAssertEqual(mst1.rootHash, mst2.rootHash, "insertion order must not affect root hash")
    }

    func testMST_InsertsAreDeterministic_LargeSet() {
        let entries = (0..<1000).map { ("file_\($0).txt", "hash_\($0)") }
        let mst1 = MerkleSearchTree()
        let mst2 = MerkleSearchTree()
        for (k, v) in entries.shuffled() { mst1.insert(key: k, value: v) }
        for (k, v) in entries.shuffled() { mst2.insert(key: k, value: v) }
        XCTAssertEqual(mst1.rootHash, mst2.rootHash)
        XCTAssertEqual(mst1.getAllEntries(), mst2.getAllEntries())
    }

    func testMST_UpdateKey_ChangesRootHash() {
        let mst1 = MerkleSearchTree()
        mst1.insert(key: "readme.md", value: "hash-v1")
        let hash1 = mst1.rootHash

        let mst2 = MerkleSearchTree()
        mst2.insert(key: "readme.md", value: "hash-v2")  // different value
        let hash2 = mst2.rootHash

        XCTAssertNotEqual(hash1, hash2, "changing a value must change the root hash")
    }

    // MARK: - MerkleSearchTree: diff

    func testMST_FindDifferences_ReturnsExactKeys() {
        let mst1 = MerkleSearchTree()
        let mst2 = MerkleSearchTree()

        for i in 0..<100 {
            let k = "file_\(i).txt"
            mst1.insert(key: k, value: "hash_\(i)")
            if i != 7 {  // file_7 missing in mst2
                mst2.insert(key: k, value: "hash_\(i)")
            }
        }
        mst2.insert(key: "file_42.txt", value: "modified_hash")  // file_42 modified in mst2

        let diffs = mst1.findDifferences(other: mst2)
        XCTAssertTrue(diffs.contains("file_7.txt"), "missing key must appear in diff")
        XCTAssertTrue(diffs.contains("file_42.txt"), "modified value must appear in diff")
        XCTAssertEqual(diffs.count, 2, "no false positives for identical keys")
    }

    func testMST_IdenticalTrees_NoDifferences() {
        let mst1 = MerkleSearchTree()
        let mst2 = MerkleSearchTree()
        let entries = [("x.txt", "hx"), ("y.txt", "hy"), ("z.txt", "hz")]
        for (k, v) in entries {
            mst1.insert(key: k, value: v)
            mst2.insert(key: k, value: v)
        }
        XCTAssertTrue(
            mst1.findDifferences(other: mst2).isEmpty,
            "identical trees must produce zero differences")
    }

    // MARK: - FastCDC: edge cases

    func testFastCDC_EmptyFile_ReturnsNoChunks() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "empty_\(UUID().uuidString).bin")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let chunks = try FastCDC().chunk(fileURL: url)
        XCTAssertTrue(chunks.isEmpty, "empty file must produce no chunks")
    }

    func testFastCDC_SmallFile_SingleChunk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "small_\(UUID().uuidString).txt")
        let content = "Hello, FolderSync!".data(using: .utf8)!
        try content.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let cdc = FastCDC(min: 1024, avg: 4096, max: 8192)
        let chunks = try cdc.chunk(fileURL: url)

        XCTAssertEqual(chunks.count, 1, "file smaller than minSize must be one chunk")
        XCTAssertEqual(chunks[0].data, content)
        XCTAssertEqual(chunks[0].offset, 0)
    }

    func testFastCDC_LargerFile_CorrectBoundaries() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "large_\(UUID().uuidString).bin")
        // Generate 256 KB of pseudo-random-but-reproducible data using a simple LCG
        var data = Data(capacity: 256 * 1024)
        var state: UInt64 = 0xDEAD_BEEF_1234_5678
        for _ in 0..<(256 * 1024) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            data.append(UInt8(state >> 56))
        }
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let minSize = 1024
        let maxSize = 8192
        let cdc = FastCDC(min: minSize, avg: 4096, max: maxSize)
        let chunks = try cdc.chunk(fileURL: url)

        XCTAssertGreaterThan(chunks.count, 1, "256 KB file must produce multiple chunks")

        var totalBytes: Int64 = 0
        for c in chunks {
            let isLastChunk = c.offset + Int64(c.data.count) == Int64(data.count)
            XCTAssertTrue(
                c.data.count >= minSize || isLastChunk,
                "chunk below minSize only acceptable as last chunk")
            XCTAssertTrue(c.data.count <= maxSize, "no chunk may exceed maxSize")
            XCTAssertEqual(c.offset, totalBytes, "chunks must be contiguous with no gaps")
            totalBytes += Int64(c.data.count)

            let expected = SHA256.hash(data: c.data).compactMap { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(c.hash, expected, "each chunk's stored hash must match its content")
        }
        XCTAssertEqual(totalBytes, Int64(data.count), "chunks must cover entire file exactly")
    }

    func testFastCDC_ContentDefinedCutPoints_AreStable() throws {
        // Prepend 1 KB to a 64 KB file. With CDC, most cut-points after the prepend should survive.
        let tempDir = FileManager.default.temporaryDirectory
        let prefix = Data(repeating: 0xFF, count: 1024)
        var body = Data(capacity: 64 * 1024)
        var state: UInt64 = 0xABCD_EF01_2345_6789
        for _ in 0..<(64 * 1024) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            body.append(UInt8(state >> 56))
        }

        let originalURL = tempDir.appendingPathComponent("cdc_orig_\(UUID().uuidString).bin")
        let prependedURL = tempDir.appendingPathComponent("cdc_prepended_\(UUID().uuidString).bin")
        try body.write(to: originalURL)
        try (prefix + body).write(to: prependedURL)
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: prependedURL)
        }

        let cdc = FastCDC(min: 1024, avg: 4096, max: 8192)
        let origChunks = try cdc.chunk(fileURL: originalURL).map(\.hash)
        let prepChunks = try cdc.chunk(fileURL: prependedURL).map(\.hash)

        // The hashes of the shared body should mostly overlap (content-defined property)
        let origSet = Set(origChunks)
        let prepSet = Set(prepChunks)
        let overlap = origSet.intersection(prepSet).count
        let total = origSet.count
        XCTAssertGreaterThan(
            overlap, total / 2,
            "CDC must reuse >50% of unmodified chunks after a prefix insertion")
    }
}
