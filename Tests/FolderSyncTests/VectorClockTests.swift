import XCTest
@testable import FolderSync

final class VectorClockTests: XCTestCase {
    func testVectorClockComparison() {
        var v1 = VectorClock()
        v1.increment(for: "peerA")
        
        var v2 = VectorClock()
        v2.increment(for: "peerA")
        
        XCTAssertEqual(v1.compare(to: v2), .equal)
        
        v1.increment(for: "peerA")
        XCTAssertEqual(v1.compare(to: v2), .successor)
        XCTAssertEqual(v2.compare(to: v1), .antecedent)
        
        v2.increment(for: "peerB")
        // v1 = {peerA: 2}, v2 = {peerA: 1, peerB: 1} -> Concurrent
        XCTAssertEqual(v1.compare(to: v2), .concurrent)
    }
    
    func testVectorClockMerge() {
        var v1 = VectorClock(versions: ["peerA": 2, "peerB": 1])
        let v2 = VectorClock(versions: ["peerA": 1, "peerB": 5, "peerC": 2])
        
        v1.merge(with: v2)
        
        XCTAssertEqual(v1.versions["peerA"], 2)
        XCTAssertEqual(v1.versions["peerB"], 5)
        XCTAssertEqual(v1.versions["peerC"], 2)
    }

    func testVectorClockComparisonWithDisjointKeys() {
        let v1 = VectorClock(versions: ["peerA": 1])
        let v2 = VectorClock(versions: ["peerB": 2])

        // Missing keys should be treated as 0, leading to concurrency
        XCTAssertEqual(v1.compare(to: v2), .concurrent)
    }
}
