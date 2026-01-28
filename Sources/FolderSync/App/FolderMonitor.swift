import Foundation
import SwiftUI

/// 文件夹监控管理器
/// 负责文件系统事件监控、文件稳定性检测和同步触发防抖
@MainActor
class FolderMonitor {
    weak var syncManager: SyncManager?

    private var monitors: [UUID: FSEventsMonitor] = [:]
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private let debounceDelay: TimeInterval = 2.0  // 2 秒防抖延迟

    // 文件写入稳定性检测：记录文件路径和上次检查的大小
    private var fileStabilityCheck: [String: (size: Int64, lastCheck: Date)] = [:]
    private let fileStabilityDelay: TimeInterval = 3.0  // 文件大小稳定3秒后才认为写入完成

    init(syncManager: SyncManager) {
        self.syncManager = syncManager
    }

    func startMonitoring(_ folder: SyncFolder) {
        guard let syncManager = syncManager else { return }

        // 注意：广播现在包含 syncID 列表，设备在发现 peer 时即可知道哪些 syncID 匹配
        // 这样可以提前过滤，只对匹配的 syncID 触发同步

        let monitor = FSEventsMonitor(path: folder.localPath.path) { [weak self] path, flags in
            guard let self = self, let syncManager = self.syncManager else { return }

            // 文件变化时直接触发统计
            Task { @MainActor in
                if let updatedFolder = syncManager.folders.first(where: { $0.id == folder.id }) {
                    syncManager.recordLocalChange(
                        for: updatedFolder, absolutePath: path, flags: flags)
                    syncManager.refreshFileCount(for: updatedFolder)
                }
            }

            // 同步仍然使用防抖机制（避免频繁同步）
            // 检查文件是否正在被写入（文件大小是否稳定）
            Task { [weak self] in
                guard let self = self, self.syncManager != nil else { return }

                // 检查文件是否存在且是文件（不是目录）
                let fileManager = FileManager.default
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                    !isDirectory.boolValue
                else {
                    // 是目录或文件不存在，直接触发同步
                    self.triggerSyncAfterDebounce(for: folder, syncID: folder.syncID)
                    return
                }

                // 检查文件是否正在写入
                let isStable = await self.checkFileStability(filePath: path)
                if isStable {
                    // 文件已稳定，触发同步
                    self.triggerSyncAfterDebounce(for: folder, syncID: folder.syncID)
                } else {
                    // 文件正在写入，等待稳定后再触发同步
                    await self.waitForFileStability(
                        filePath: path, folder: folder, syncID: folder.syncID)
                }
            }
        }
        monitor.start()
        monitors[folder.id] = monitor
    }

    func stopMonitoring(_ folder: SyncFolder) {
        monitors[folder.id]?.stop()
        monitors.removeValue(forKey: folder.id)
        // 取消该文件夹的防抖任务
        debounceTasks[folder.syncID]?.cancel()
        debounceTasks.removeValue(forKey: folder.syncID)
    }

    func cancelAll() {
        for task in debounceTasks.values {
            task.cancel()
        }
        debounceTasks.removeAll()
        for monitor in monitors.values {
            monitor.stop()
        }
        monitors.removeAll()
    }

    /// 检查文件是否稳定（文件大小在短时间内没有变化）
    private func checkFileStability(filePath: String) async -> Bool {
        let fileManager = FileManager.default

        guard let attributes = try? fileManager.attributesOfItem(atPath: filePath),
            let fileSize = attributes[.size] as? Int64
        else {
            // 无法获取文件大小，认为不稳定
            return false
        }

        let now = Date()
        let fileKey = filePath

        // 检查是否有之前的记录
        if let previous = fileStabilityCheck[fileKey] {
            // 如果文件大小没有变化，且距离上次检查已超过稳定时间
            if previous.size == fileSize {
                let timeSinceLastCheck = now.timeIntervalSince(previous.lastCheck)
                if timeSinceLastCheck >= fileStabilityDelay {
                    // 文件大小稳定，清除记录
                    fileStabilityCheck.removeValue(forKey: fileKey)
                    return true
                }
            } else {
                // 文件大小变化了，更新记录
                fileStabilityCheck[fileKey] = (size: fileSize, lastCheck: now)
                return false
            }
        } else {
            // 首次检查，记录当前大小
            fileStabilityCheck[fileKey] = (size: fileSize, lastCheck: now)
            return false
        }

        return false
    }

    /// 等待文件写入完成（文件大小稳定）
    private func waitForFileStability(filePath: String, folder: SyncFolder, syncID: String) async {
        let maxWaitTime: TimeInterval = 60.0  // 最多等待60秒
        let checkInterval: TimeInterval = 1.0  // 每秒检查一次
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < maxWaitTime {
            // 等待一段时间后检查
            try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))

            let isStable = await checkFileStability(filePath: filePath)
            if isStable {
                triggerSyncAfterDebounce(for: folder, syncID: syncID)
                return
            }
        }

        // 超时后仍然触发同步（可能文件很大，需要更长时间）
        triggerSyncAfterDebounce(for: folder, syncID: syncID)
    }

    /// 防抖触发同步
    private func triggerSyncAfterDebounce(for folder: SyncFolder, syncID: String) {
        guard syncManager != nil else { return }

        // 取消之前的防抖任务
        debounceTasks[syncID]?.cancel()

        // 创建新的防抖任务
        let debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.debounceDelay ?? 2.0) * 1_000_000_000)

            guard !Task.isCancelled else { return }
            guard let self = self, let syncManager = self.syncManager else { return }

            // 检查是否有同步正在进行
            let hasSyncInProgress = await MainActor.run {
                let allPeers = syncManager.peerManager.allPeers
                for peerInfo in allPeers {
                    let syncKey = "\(syncID):\(peerInfo.peerIDString)"
                    if syncManager.syncInProgress.contains(syncKey) {
                        return true
                    }
                }
                return false
            }

            if hasSyncInProgress {
                print("[FolderMonitor] ⏭️ 同步已进行中，跳过防抖触发的同步: \(syncID)")
                return
            }

            print("[FolderMonitor] 🔄 防抖延迟结束，开始同步: \(syncID)")
            syncManager.triggerSync(for: folder)
        }

        debounceTasks[syncID] = debounceTask
    }

    /// 检查文件是否稳定（供外部调用，用于 calculateFullState）
    func isFileStable(filePath: String) -> Bool {
        let fileKey = filePath
        if let stability = fileStabilityCheck[fileKey] {
            let timeSinceLastCheck = Date().timeIntervalSince(stability.lastCheck)
            return timeSinceLastCheck >= fileStabilityDelay
        }
        return true  // 没有记录，认为稳定
    }

}
