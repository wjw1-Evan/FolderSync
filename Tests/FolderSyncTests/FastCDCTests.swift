import XCTest

@testable import FolderSync

final class FastCDCTests: XCTestCase {
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            // Simple LCG for deterministic test data
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return state
        }
    }

    func testChunkingConsistency() throws {
        let fastCDC = FastCDC(min: 1024, avg: 4096, max: 8192)

        // Create deterministic dummy file
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let testFileURL = tempDir.appendingPathComponent("test_consistency.dat")
        var rng = SeededGenerator(state: 12345)
        let testData = Data((0..<10_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        try testData.write(to: testFileURL)

        defer { try? fileManager.removeItem(at: testFileURL) }

        let chunks1 = try fastCDC.chunk(fileURL: testFileURL)
        let chunks2 = try fastCDC.chunk(fileURL: testFileURL)

        XCTAssertEqual(chunks1.count, chunks2.count)
        for i in 0..<chunks1.count {
            XCTAssertEqual(chunks1[i].hash, chunks2[i].hash)
            XCTAssertEqual(chunks1[i].offset, chunks2[i].offset)
        }

        // Ensure offsets are contiguous and cover the full file
        let reconstructed = chunks1.enumerated().reduce(into: Data()) { acc, pair in
            let (_, chunk) = pair
            acc.append(chunk.data)
        }
        XCTAssertEqual(reconstructed.count, testData.count)
        XCTAssertEqual(reconstructed, testData)
    }

    func testChunkingResilienceToSmallChanges() throws {
        let fastCDC = FastCDC(min: 256, avg: 1024, max: 2048)
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory

        let file1URL = tempDir.appendingPathComponent("file1.dat")
        let file2URL = tempDir.appendingPathComponent("file2.dat")

        var rng = SeededGenerator(state: 42)
        let baseData = Data((0..<5000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        try baseData.write(to: file1URL)

        // Insert a byte at the beginning
        var shiftedData = Data([0xFF])
        shiftedData.append(baseData)
        try shiftedData.write(to: file2URL)

        defer {
            try? fileManager.removeItem(at: file1URL)
            try? fileManager.removeItem(at: file2URL)
        }

        let chunks1 = try fastCDC.chunk(fileURL: file1URL)
        let chunks2 = try fastCDC.chunk(fileURL: file2URL)

        // With CDC, most chunks (except the first one or two) should still be identical
        let hashes1 = Set(chunks1.map { $0.hash })
        let hashes2 = Set(chunks2.map { $0.hash })

        let commonHashes = hashes1.intersection(hashes2)

        // At least 50% of chunks should be common even with a shift
        XCTAssertGreaterThan(commonHashes.count, hashes1.count / 2)
    }

    func testChunkSizesRespectBounds() throws {
        let min = 512
        let avg = 1024
        let max = 2048
        let fastCDC = FastCDC(min: min, avg: avg, max: max)

        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("test_bounds.dat")

        var rng = SeededGenerator(state: 999)
        let testData = Data((0..<12_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        try testData.write(to: fileURL)

        defer { try? fileManager.removeItem(at: fileURL) }

        let chunks = try fastCDC.chunk(fileURL: fileURL)

        // All chunks must be <= max; all except possibly the last must be >= min
        for (index, chunk) in chunks.enumerated() {
            XCTAssertLessThanOrEqual(chunk.data.count, max)
            if index < chunks.count - 1 {  // allow final remainder to be shorter
                XCTAssertGreaterThanOrEqual(chunk.data.count, min)
            }
        }

        // Offsets should be contiguous and cover the whole file
        var expectedOffset: Int64 = 0
        for chunk in chunks {
            XCTAssertEqual(chunk.offset, expectedOffset)
            expectedOffset += Int64(chunk.data.count)
        }
        XCTAssertEqual(expectedOffset, Int64(testData.count))
    }

    func testSmallFileProducesSingleChunk() throws {
        let fastCDC = FastCDC(min: 2048, avg: 4096, max: 8192)
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("test_small.dat")

        let data = Data([UInt8](0..<64))  // Much smaller than min
        try data.write(to: fileURL)

        defer { try? fileManager.removeItem(at: fileURL) }

        let chunks = try fastCDC.chunk(fileURL: fileURL)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.data, data)
        XCTAssertEqual(chunks.first?.offset, 0)
    }
}
