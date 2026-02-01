import XCTest

@testable import FolderSync

final class MerkleTreeDiffTests: XCTestCase {

    func testIdenticalTreesParams() {
        let mst1 = MerkleSearchTree()
        mst1.insert(key: "file1.txt", value: "hash1")
        mst1.insert(key: "file2.txt", value: "hash2")

        let mst2 = MerkleSearchTree()
        mst2.insert(key: "file1.txt", value: "hash1")
        mst2.insert(key: "file2.txt", value: "hash2")

        let diffs = mst1.findDifferences(other: mst2)
        XCTAssertTrue(diffs.isEmpty, "Identical trees should have no differences")
    }

    func testDifferentValues() {
        let mst1 = MerkleSearchTree()
        mst1.insert(key: "file1.txt", value: "hash1")

        let mst2 = MerkleSearchTree()
        mst2.insert(key: "file1.txt", value: "hash1_modified")

        let diffs = mst1.findDifferences(other: mst2)
        XCTAssertTrue(diffs.contains("file1.txt"), "Should detect file content change")
        XCTAssertEqual(diffs.count, 1)
    }

    func testExtraFiles() {
        let mst1 = MerkleSearchTree()
        mst1.insert(key: "file1.txt", value: "hash1")

        let mst2 = MerkleSearchTree()
        mst2.insert(key: "file1.txt", value: "hash1")
        mst2.insert(key: "file2.txt", value: "hash2")

        let diffs = mst1.findDifferences(other: mst2)
        XCTAssertTrue(diffs.contains("file2.txt"), "Should detect extra file in one tree")
        XCTAssertEqual(diffs.count, 1)
    }

    func testTreeDivergence() {
        // Construct slightly larger trees to trigger levels
        let mst1 = MerkleSearchTree()
        let mst2 = MerkleSearchTree()

        // Base content
        for i in 0..<10 {
            mst1.insert(key: "file\(i)", value: "hash\(i)")
            mst2.insert(key: "file\(i)", value: "hash\(i)")
        }

        // Modify one file
        mst2.insert(key: "file5", value: "hash5_mod")

        let diffs = mst1.findDifferences(other: mst2)
        XCTAssertTrue(diffs.contains("file5"), "Should find the single modified file")
        XCTAssertEqual(diffs.count, 1)
    }
}
