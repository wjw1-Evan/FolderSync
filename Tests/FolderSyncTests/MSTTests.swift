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
}
