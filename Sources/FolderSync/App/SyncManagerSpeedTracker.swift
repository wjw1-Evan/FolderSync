import Foundation

/// 速度统计扩展
/// 负责上传和下载速度的统计
extension SyncManager {
    func addUploadBytes(_ n: Int64) {
        pendingUploadBytes += n
        let now = Date()
        if now.timeIntervalSince(lastUploadUpdate) > 0.1 || pendingUploadBytes > 1024 * 1024 {
            uploadSamples.append((now, pendingUploadBytes))
            pendingUploadBytes = 0
            lastUploadUpdate = now
        }
    }

    func addDownloadBytes(_ n: Int64) {
        pendingDownloadBytes += n
        let now = Date()
        if now.timeIntervalSince(lastDownloadUpdate) > 0.1 || pendingDownloadBytes > 1024 * 1024 {
            downloadSamples.append((now, pendingDownloadBytes))
            pendingDownloadBytes = 0
            lastDownloadUpdate = now
        }
    }

    /// 每秒调用一次，更新当前速度和历史纪录
    func updateSpeedHistory() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-speedWindow)

        // 更新上传速度
        uploadSamples.removeAll { $0.0 < cutoff }
        let uploadSum = uploadSamples.reduce(Int64(0)) { $0 + $1.1 }
        let currentUploadSpeed = Double(uploadSum) / speedWindow
        uploadSpeedBytesPerSec = currentUploadSpeed

        // 更新上传历史
        uploadSpeedHistory.append(currentUploadSpeed)
        if uploadSpeedHistory.count > 60 {
            uploadSpeedHistory.removeFirst()
        }

        // 更新下载速度
        downloadSamples.removeAll { $0.0 < cutoff }
        let downloadSum = downloadSamples.reduce(Int64(0)) { $0 + $1.1 }
        let currentDownloadSpeed = Double(downloadSum) / speedWindow
        downloadSpeedBytesPerSec = currentDownloadSpeed

        // 更新下载历史
        downloadSpeedHistory.append(currentDownloadSpeed)
        if downloadSpeedHistory.count > 60 {
            downloadSpeedHistory.removeFirst()
        }

        // 更新待处理文件数量历史
        pendingUploadHistory.append(Double(pendingUploadCount))
        if pendingUploadHistory.count > 60 {
            pendingUploadHistory.removeFirst()
        }

        pendingDownloadHistory.append(Double(pendingDownloadCount))
        if pendingDownloadHistory.count > 60 {
            pendingDownloadHistory.removeFirst()
        }
    }
}
