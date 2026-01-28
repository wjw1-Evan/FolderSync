import Foundation

/// 速度统计扩展
/// 负责上传和下载速度的统计
extension SyncManager {
    func addUploadBytes(_ n: Int64) {
        uploadSamples.append((Date(), n))
        let cutoff = Date().addingTimeInterval(-speedWindow)
        uploadSamples.removeAll { $0.0 < cutoff }
        let sum = uploadSamples.reduce(Int64(0)) { $0 + $1.1 }
        uploadSpeedBytesPerSec = Double(sum) / speedWindow
    }

    func addDownloadBytes(_ n: Int64) {
        downloadSamples.append((Date(), n))
        let cutoff = Date().addingTimeInterval(-speedWindow)
        downloadSamples.removeAll { $0.0 < cutoff }
        let sum = downloadSamples.reduce(Int64(0)) { $0 + $1.1 }
        downloadSpeedBytesPerSec = Double(sum) / speedWindow
    }
}
