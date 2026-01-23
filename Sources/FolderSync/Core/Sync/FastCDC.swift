import Crypto
import Foundation

public struct Chunk {
    public let hash: String
    public let data: Data
    public let offset: Int64
}

public class FastCDC {
    private let minSize: Int
    private let avgSize: Int
    private let maxSize: Int
    private static let gearTable: [UInt64] = {
        var value: UInt64 = 0x123_4567_89AB_CDEF
        var table: [UInt64] = []
        for _ in 0..<256 {
            // Simple LCG to generate deterministic pseudo-random gear values
            value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            table.append(value)
        }
        return table
    }()

    public init(min: Int = 4096, avg: Int = 16384, max: Int = 65536) {
        self.minSize = min
        self.avgSize = avg
        self.maxSize = max
    }

    public func chunk(fileURL: URL) throws -> [Chunk] {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        var chunks: [Chunk] = []
        var fingerprint: UInt64 = 0
        var chunkStart = 0
        let normalMask: UInt64 = 0x3F  // Probability 1/64
        let aggressiveMask: UInt64 = 0x1F  // Probability 1/32 when exceeding avg size

        for (index, byte) in data.enumerated() {
            fingerprint = (fingerprint << 1) &+ FastCDC.gearTable[Int(byte)]
            let currentLength = index - chunkStart + 1
            let remaining = data.count - chunkStart
            let maxChunk = min(maxSize, remaining)

            var shouldCut = currentLength >= maxChunk
            if !shouldCut && currentLength >= minSize {
                let mask = currentLength < avgSize ? normalMask : aggressiveMask
                if (fingerprint & mask) == 0 {
                    shouldCut = true
                }
            }

            if shouldCut {
                let end = chunkStart + currentLength
                let chunkData = data.subdata(in: chunkStart..<end)
                chunks.append(createChunk(data: chunkData, offset: Int64(chunkStart)))
                chunkStart = index + 1
                fingerprint = 0
            }
        }

        if chunkStart < data.count {
            let chunkData = data.subdata(in: chunkStart..<data.count)
            chunks.append(createChunk(data: chunkData, offset: Int64(chunkStart)))
        }

        return chunks
    }

    private func createChunk(data: Data, offset: Int64) -> Chunk {
        let hash = SHA256.hash(data: data)
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        return Chunk(hash: hashString, data: data, offset: offset)
    }
}
