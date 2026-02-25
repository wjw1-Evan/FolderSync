import Crypto
import XCTest

@testable import FolderSync

final class MSTDeterminismTests: XCTestCase {

    func testMSTOrderDeterminism() {
        let mst1 = MerkleSearchTree()
        mst1.insert(key: "A", value: "v1")
        mst1.insert(key: "C", value: "v1")

        let mst2 = MerkleSearchTree()
        mst2.insert(key: "C", value: "v1")
        mst2.insert(key: "A", value: "v1")

        let hash1 = mst1.rootHash
        let hash2 = mst2.rootHash

        print("MST1 Hash: \(hash1 ?? "nil")")
        print("MST2 Hash: \(hash2 ?? "nil")")

        XCTAssertEqual(hash1, hash2, "MST root hash should be independent of insertion order")
    }
}
