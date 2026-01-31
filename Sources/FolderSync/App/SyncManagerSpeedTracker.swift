import Foundation

/// 速度统计扩展
/// 负责上传和下载速度的统计
extension SyncManager {
    func addUploadBytes(_ n: Int64) {
        pendingUploadBytes += n
        let now = Date()
        if now.timeIntervalSince(lastUploadUpdate) > 0.1 || pendingUploadBytes > 1024 * 1024 {
            // Commit pending bytes to samples
            // 使用当前 pendingBytes 作为样本值（这段时间内的增量）
            uploadSamples.append((now, pendingUploadBytes))

            // 重置待处理
            pendingUploadBytes = 0
            lastUploadUpdate = now

            // 计算速度
            let cutoff = now.addingTimeInterval(-speedWindow)
            uploadSamples.removeAll { $0.0 < cutoff }
            let sum = uploadSamples.reduce(Int64(0)) { $0 + $1.1 }
            uploadSpeedBytesPerSec = Double(sum) / speedWindow
        }
    }

    func addDownloadBytes(_ n: Int64) {
        pendingDownloadBytes += n
        let now = Date()
        if now.timeIntervalSince(lastDownloadUpdate) > 0.1 || pendingDownloadBytes > 1024 * 1024 {
            // Commit pending bytes to samples
            downloadSamples.append((now, pendingDownloadBytes))

            // 重置待处理
            pendingDownloadBytes = 0
            lastDownloadUpdate = now

            // 计算速度
            let cutoff = now.addingTimeInterval(-speedWindow)
            downloadSamples.removeAll { $0.0 < cutoff }
            let sum = downloadSamples.reduce(Int64(0)) { $0 + $1.1 }
            downloadSpeedBytesPerSec = Double(sum) / speedWindow
        }
    }
}
