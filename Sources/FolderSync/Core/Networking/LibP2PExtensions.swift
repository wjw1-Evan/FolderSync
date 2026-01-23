import LibP2P
import LibP2PCore
import NIOCore
import Foundation

extension Request {
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(self.payload.readableBytesView))
    }
}

extension SyncResponse: AsyncResponseEncodable {
    public func encodeResponse(for request: Request) async throws -> RawResponse {
        do {
            let data = try JSONEncoder().encode(self)
            var buffer = request.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            return RawResponse(payload: buffer)
        } catch {
            throw error
        }
    }
}

extension Application {
    public func requestSync<T: Decodable>(_ message: SyncRequest, to peer: PeerID) async throws -> T {
        let data = try JSONEncoder().encode(message)
        // newRequest returns a future that completes with the response Data
        let responseData = try await self.newRequest(to: peer, forProtocol: "folder-sync/1.0.0", withRequest: data).get()
        return try JSONDecoder().decode(T.self, from: responseData)
    }
}
