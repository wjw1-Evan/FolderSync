import Foundation
import Crypto

public struct Chunk {
    public let hash: String
    public let data: Data
    public let offset: Int64
}

public class FastCDC {
    private let minSize: Int
    private let avgSize: Int
    private let maxSize: Int
    
    public init(min: Int = 4096, avg: Int = 16384, max: Int = 65536) {
        self.minSize = min
        self.avgSize = avg
        self.maxSize = max
    }
    
    public func chunk(fileURL: URL) throws -> [Chunk] {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        var chunks: [Chunk] = []
        var offset: Int = 0
        
        while offset < data.count {
            let remaining = data.count - offset
            if remaining <= minSize {
                let chunkData = data.subdata(in: offset..<data.count)
                chunks.append(createChunk(data: chunkData, offset: Int64(offset)))
                break
            }
            
            let chunkSize = findCutPoint(in: data, start: offset)
            let chunkData = data.subdata(in: offset..<(offset + chunkSize))
            chunks.append(createChunk(data: chunkData, offset: Int64(offset)))
            offset += chunkSize
        }
        
        return chunks
    }
    
    private func findCutPoint(in data: Data, start: Int) -> Int {
        let maxLen = min(maxSize, data.count - start)
        if maxLen <= minSize { return maxLen }
        
        // Skip minSize
        var i = minSize
        let mask = UInt32(avgSize - 1)
        var fingerPrint: UInt32 = 0
        
        // Simple rolling hash (Gear hash style for demonstration, can be improved)
        while i < maxLen {
            let byte = data[start + i]
            fingerPrint = (fingerPrint << 1) &+ UInt32(byte)
            
            if (fingerPrint & mask) == 0 {
                return i + 1
            }
            i += 1
        }
        
        return maxLen
    }
    
    private func createChunk(data: Data, offset: Int64) -> Chunk {
        let hash = SHA256.hash(data: data)
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        return Chunk(hash: hashString, data: data, offset: offset)
    }
}
