import XCTest
@testable import FolderSync

final class MSTTests: XCTestCase {
    func testMSTHashConsistency() {
        let mst1 = MerkleSearchTree()
        let mst2 = MerkleSearchTree()
        
        let data = [
            "file1": "hash_a",
            "file2": "hash_b",
            "file3": "hash_c"
        ]
        
        for (k, v) in data {
            mst1.insert(key: k, value: v)
            mst2.insert(key: k, value: v)
        }
        
        XCTAssertEqual(mst1.rootHash, mst2.rootHash)
    }
    
    func testMSTDifferenceDetection() {
        let mst1 = MerkleSearchTree()
        let mst2 = MerkleSearchTree()
        
        mst1.insert(key: "file1", value: "hash_a")
        mst1.insert(key: "file2", value: "hash_b")
        
        mst2.insert(key: "file1", value: "hash_a")
        mst2.insert(key: "file2", value: "hash_changed")
        
        XCTAssertNotEqual(mst1.rootHash, mst2.rootHash)
    }

    func testMSTEntriesAndDiffBehavior() {
        let baseMST = MerkleSearchTree()
        baseMST.insert(key: "file1", value: "hash_a")
        baseMST.insert(key: "file2", value: "hash_b")

        XCTAssertEqual(baseMST.getAllEntries(), ["file1": "hash_a", "file2": "hash_b"])

        // When hashes match, diff should be empty
        let identicalMST = MerkleSearchTree()
        identicalMST.insert(key: "file1", value: "hash_a")
        identicalMST.insert(key: "file2", value: "hash_b")
        XCTAssertEqual(baseMST.diff(remoteHash: identicalMST.rootHash ?? "", remoteMST: identicalMST), [])

        // When hashes differ, simplified diff returns local keys
        let remoteMST = MerkleSearchTree()
        remoteMST.insert(key: "file1", value: "hash_a")
        remoteMST.insert(key: "file2", value: "hash_changed")
        remoteMST.insert(key: "file3", value: "hash_new")
        let diffKeys = baseMST.diff(remoteHash: remoteMST.rootHash ?? "", remoteMST: remoteMST)
        XCTAssertEqual(Set(diffKeys), Set(["file1", "file2"]))
    }
}
