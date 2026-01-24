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
    public func requestSync<T: Decodable>(_ message: SyncRequest, to peer: PeerID, timeout: TimeInterval = 30.0, maxRetries: Int = 3, peerAddresses: [Multiaddr]? = nil) async throws -> T {
        let data = try JSONEncoder().encode(message)
        let timeoutSeconds: TimeInterval = timeout
        
        var lastError: Error?
        
        // 重试机制：首次连接可能需要更多时间
        for attempt in 1...maxRetries {
            do {
                // 对于重试，每次增加超时时间（首次连接需要更长时间）
                let attemptTimeout = timeoutSeconds * Double(attempt)
                
                // newRequest returns a future that completes with the response Data
                // Note: swift-libp2p's newRequest may not support passing addresses directly
                // If peerAddresses are provided, we need to ensure libp2p knows about them
                // The addresses should already be in the peer store from connectToDiscoveredPeer
                let responseData = try await withTimeout(seconds: attemptTimeout) {
                    try await self.newRequest(to: peer, forProtocol: "folder-sync/1.0.0", withRequest: data).get()
                }
                return try JSONDecoder().decode(T.self, from: responseData)
            } catch {
                lastError = error
                let errorString = String(describing: error)
                let isTimeout = errorString.contains("TimedOut") || 
                               errorString.contains("Timeout") ||
                               (error as NSError?)?.code == 2
                
                if isTimeout && attempt < maxRetries {
                    // 指数退避：等待时间逐渐增加
                    let backoffDelay = Double(attempt) * 2.0 // 2s, 4s, 6s...
                    print("[LibP2P] ⚠️ 请求超时（尝试 \(attempt)/\(maxRetries)），等待 \(String(format: "%.1f", backoffDelay)) 秒后重试...")
                    try? await Task.sleep(nanoseconds: UInt64(backoffDelay * 1_000_000_000))
                    continue
                }
                
                // 最后一次尝试失败或非超时错误，抛出异常
                if isTimeout {
                    throw NSError(
                        domain: "LibP2P.Application.SingleBufferingRequest.Errors",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey: "请求超时（已重试 \(maxRetries) 次）。对等点可能未响应或网络连接较慢。"
                        ]
                    )
                }
                throw error
            }
        }
        
        // 所有重试都失败
        throw lastError ?? NSError(
            domain: "LibP2P.Application.SingleBufferingRequest.Errors",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "请求失败：未知错误"]
        )
    }
}

/// 带超时的异步操作包装器
private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        // 启动实际操作
        group.addTask {
            try await operation()
        }
        
        // 启动超时任务
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw NSError(
                domain: "Timeout",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "操作超时"]
            )
        }
        
        // 等待第一个完成的任务
        guard let result = try await group.next() else {
            throw NSError(
                domain: "Timeout",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "操作失败"]
            )
        }
        
        // 取消其他任务
        group.cancelAll()
        
        return result
    }
}
