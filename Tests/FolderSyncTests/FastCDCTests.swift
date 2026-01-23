import XCTest
@testable import FolderSync

final class FastCDCTests: XCTestCase {
    func testChunkingConsistency() throws {
        let fastCDC = FastCDC(min: 1024, avg: 4096, max: 8192)
        
        // Create a dummy file
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let testFileURL = tempDir.appendingPathComponent("test_consistency.dat")
        let testData = Data((0..<10000).map { _ in UInt8.random(in: 0...255) })
        try testData.write(to: testFileURL)
        
        defer { try? fileManager.removeItem(at: testFileURL) }
        
        let chunks1 = try fastCDC.chunk(fileURL: testFileURL)
        let chunks2 = try fastCDC.chunk(fileURL: testFileURL)
        
        XCTAssertEqual(chunks1.count, chunks2.count)
        for i in 0..<chunks1.count {
            XCTAssertEqual(chunks1[i].hash, chunks2[i].hash)
            XCTAssertEqual(chunks1[i].offset, chunks2[i].offset)
        }
    }
    
    func testChunkingResilienceToSmallChanges() throws {
        let fastCDC = FastCDC(min: 256, avg: 1024, max: 2048)
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        
        let file1URL = tempDir.appendingPathComponent("file1.dat")
        let file2URL = tempDir.appendingPathComponent("file2.dat")
        
        var baseData = Data((0..<5000).map { _ in UInt8.random(in: 0...255) })
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
        print("Common hashes: \(commonHashes.count) out of \(hashes1.count)")
        
        // At least 50% of chunks should be common even with a shift
        XCTAssertGreaterThan(commonHashes.count, hashes1.count / 2)
    }
}
