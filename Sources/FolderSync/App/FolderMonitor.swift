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

    // 事件缓冲：syncID -> (path -> flags)
    private var eventBuffer: [String: [String: FSEventStreamEventFlags]] = [:]

    // 文件写入稳定性检测：记录文件路径和上次检查的大小
    private var fileStabilityCheck: [String: (size: Int64, lastCheck: Date)] = [:]
    private let fileStabilityDelay: TimeInterval = 3.0  // 文件大小稳定3秒后才认为写入完成

    init(syncManager: SyncManager) {
        self.syncManager = syncManager
    }

    func startMonitoring(_ folder: SyncFolder) {
        guard syncManager != nil else { return }

        // 注意：广播现在包含 syncID 列表，设备在发现 peer 时即可知道哪些 syncID 匹配
        // 这样可以提前过滤，只对匹配的 syncID 触发同步

        let monitor = FSEventsMonitor(path: folder.localPath.path) { [weak self] path, flags in
            guard let self = self else { return }

            Task { @MainActor in
                self.bufferEvent(path, flags: flags, for: folder)
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
                self.triggerSyncAfterDebounce(for: folder, syncID: syncID)
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
        debounceTasks[syncID] = Task { [weak self] in
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
                AppLogger.syncPrint("[FolderMonitor] ⏭️ 同步已进行中，延迟重试: \(syncID)")
                self.triggerSyncAfterDebounce(for: folder, syncID: syncID)
                return
            }

            AppLogger.syncPrint("[FolderMonitor] 🔄 防抖延迟结束，开始同步: \(syncID)")
            syncManager.triggerSync(for: folder)
        }
    }

    /// 缓冲事件并延迟处理
    private func bufferEvent(_ path: String, flags: FSEventStreamEventFlags, for folder: SyncFolder)
    {
        let syncID = folder.syncID

        // 初始化缓冲区
        if eventBuffer[syncID] == nil {
            eventBuffer[syncID] = [:]
        }
        // 累积标志位 (OR 操作)，以捕获所有类型的变更
        let currentFlags =
            eventBuffer[syncID]?[path] ?? FSEventStreamEventFlags(kFSEventStreamEventFlagNone)
        eventBuffer[syncID]?[path] = currentFlags | flags

        // 取消现有的处理任务，重新计时（防抖）
        debounceTasks[syncID]?.cancel()

        debounceTasks[syncID] = Task { [weak self] in
            // 等待防抖延迟，通过这种方式聚合短时间内的多个文件事件
            try? await Task.sleep(nanoseconds: UInt64(self?.debounceDelay ?? 2.0) * 1_000_000_000)

            guard !Task.isCancelled else { return }
            guard let self = self, let syncManager = self.syncManager else { return }

            // 提取并清空缓冲区
            let pathsAndFlags = self.eventBuffer[syncID] ?? [:]
            self.eventBuffer[syncID]?.removeAll()

            if pathsAndFlags.isEmpty { return }
            let pathsToProcess = Set(pathsAndFlags.keys)

            AppLogger.syncPrint("[FolderMonitor] 📦 批量处理 \(pathsToProcess.count) 个文件变更事件: \(syncID)")

            // 1. 批量记录所有变更（使用新的批量处理接口）
            if let updatedFolder = await MainActor.run(body: {
                syncManager.folders.first(where: { $0.id == folder.id })
            }) {
                // 使用 recordBatchLocalChanges 替代循环调用 recordLocalChange
                await syncManager.recordBatchLocalChanges(
                    for: updatedFolder, paths: pathsToProcess, flags: pathsAndFlags)

                // 2. 刷新统计频率减低（使用增量更新）- 已集成在 recordBatchLocalChanges 内部，但为了保险起见，保留这里
                // 注意：recordBatchLocalChanges 内部已经调用了 refreshFileCount，所以这里可以省略，或者保留作为冗余
                // 为避免重复计算，这里注释掉，依赖 recordBatchLocalChanges 内部调用
                // syncManager.refreshFileCount(for: updatedFolder, changedPaths: pathsToProcess)

                // 3. 检查同步状态并触发同步
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
                    AppLogger.syncPrint("[FolderMonitor] ⏭️ 同步已进行中，忽略本次触发（由后续同步循环处理）: \(syncID)")
                    return
                }

                AppLogger.syncPrint("[FolderMonitor] 🔄 批量事件触发同步: \(syncID)")
                syncManager.triggerSync(for: updatedFolder)
            }
        }
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
