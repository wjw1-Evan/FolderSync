import Combine
import CoreServices
import Crypto
import SwiftUI

@MainActor
public class SyncManager: ObservableObject {
    @Published var folders: [SyncFolder] = []
    @Published var uploadSpeedBytesPerSec: Double = 0
    @Published var downloadSpeedBytesPerSec: Double = 0
    @Published var pendingTransferFileCount: Int = 0
    let p2pNode = P2PNode()

    // 使用统一的 Peer 管理器
    public var peerManager: PeerManager {
        return p2pNode.peerManager
    }

    // 使用统一的 SyncID 管理器
    public let syncIDManager = SyncIDManager()

    // 兼容性：提供 peers 属性（从 peerManager 获取）
    @Published var peers: [PeerID] = []

    // 速度统计
    var uploadSamples: [(Date, Int64)] = []
    var downloadSamples: [(Date, Int64)] = []
    let speedWindow: TimeInterval = 3

    // 同步状态管理
    var lastKnownLocalPaths: [String: Set<String>] = [:]
    var lastKnownMetadata: [String: [String: FileMetadata]] = [:]  // syncID -> [path: metadata] 用于重命名检测
    var deletedRecords: [String: Set<String>] = [:]  // 旧格式，用于兼容
    var syncInProgress: Set<String> = []  // 正在同步的 (syncID, peerID) 组合，格式: "syncID:peerID"

    // 新的统一状态存储（每个 syncID 一个）
    var fileStateStores: [String: FileStateStore] = [:]

    // 去重机制：记录最近处理的变更，避免短时间内重复记录
    var recentChanges: [String: Date] = [:]  // "syncID:relativePath" -> 时间戳
    let changeDeduplicationWindow: TimeInterval = 1.0  // 1秒内的重复变更会被忽略

    // 重命名检测：记录可能的重命名操作（旧路径 -> 等待新路径）
    var pendingRenames: [String: (hash: String, timestamp: Date)] = [:]  // "syncID:relativePath" -> (哈希值, 时间戳)
    let renameDetectionWindow: TimeInterval = 2.0  // 2秒内检测重命名
    var peerStatusCheckTask: Task<Void, Never>?
    var peersSyncTask: Task<Void, Never>?  // 定期同步 peers 数组的任务
    var peerDiscoveryTask: Task<Void, Never>?  // 对等点发现处理任务

    // 同步写入冷却：对“某个 syncID 下的某个路径”的最近一次同步落地写入打标。
    // 用于忽略该路径由同步写入引发的 FSEvents，避免把远端落地误判为本地编辑。
    var syncWriteCooldown: [String: Date] = [:]  // "syncID:path" -> 最后写入时间
    var syncCooldownDuration: TimeInterval = 5.0  // 写入后 N 秒内忽略该路径的本地事件

    // 按 peer-folder 对记录的同步冷却时间，用于避免频繁同步
    var peerSyncCooldown: [String: Date] = [:]  // "peerID:syncID" -> 最后同步完成时间
    var peerSyncCooldownDuration: TimeInterval = 30.0  // 同步完成后30秒内不重复同步

    // 设备统计（用于触发UI更新）
    @Published var onlineDeviceCountValue: Int = 1  // 包括自身，默认为1
    @Published var offlineDeviceCountValue: Int = 0
    @Published var allDevicesValue: [DeviceInfo] = []  // 设备列表（用于触发UI更新）

    // 模块化组件
    var folderMonitor: FolderMonitor!
    var folderStatistics: FolderStatistics!
    var p2pHandlers: P2PHandlers!
    var fileTransfer: FileTransfer!
    var syncEngine: SyncEngine!

    public init() {
        if AppPaths.isRunningTests {
            // 测试中需要更频繁地触发同步（大量快速操作），缩短 peer 冷却期避免漏同步。
            self.peerSyncCooldownDuration = 1.0
        }

        if !AppPaths.isRunningTests {
            // 运行环境检测（测试环境跳过，避免噪音/污染用户数据目录）
            AppLogger.syncPrint("\n[EnvironmentCheck] 开始环境检测...")
            let reports = EnvironmentChecker.runAllChecks()
            EnvironmentChecker.printReport(reports)

            // Load from storage
            do {
                let loadedFolders = try StorageManager.shared.getAllFolders()
                var normalized: [SyncFolder] = []
                if !loadedFolders.isEmpty {
                    for var folder in loadedFolders {
                        // 启动时清理可能遗留的“同步中”状态，避免界面一直卡在同步中
                        if folder.status == .syncing {
                            folder.status = .synced
                            folder.syncProgress = 0
                            folder.lastSyncMessage = nil
                            // 持久化修正，防止下次启动再次卡住
                            do {
                                try StorageManager.shared.saveFolder(folder)
                            } catch {
                                AppLogger.syncPrint("[SyncManager] ⚠️ 无法保存同步状态修正: \(error)")
                            }
                        }
                        normalized.append(folder)
                        // 注册 syncID 到管理器
                        let registered = syncIDManager.registerSyncID(
                            folder.syncID, folderID: folder.id)
                        if !registered {
                            // 诊断注册失败的原因
                            if let existingInfo = syncIDManager.getSyncIDInfo(folder.syncID) {
                                if existingInfo.folderID == folder.id {
                                    // 同一个文件夹，syncID 已存在（可能是重复加载）
                                    AppLogger.syncPrint(
                                        "[SyncManager] ℹ️ syncID 已注册（同一文件夹）: \(folder.syncID)")
                                } else {
                                    // syncID 被其他文件夹使用
                                    AppLogger.syncPrint(
                                        "[SyncManager] ⚠️ 警告: syncID 已被其他文件夹使用: \(folder.syncID)")
                                    AppLogger.syncPrint("[SyncManager]   当前文件夹 ID: \(folder.id)")
                                    AppLogger.syncPrint(
                                        "[SyncManager]   已注册文件夹 ID: \(existingInfo.folderID)")
                                }
                            } else if let existingSyncID = syncIDManager.getSyncID(for: folder.id) {
                                // folderID 已关联其他 syncID
                                AppLogger.syncPrint("[SyncManager] ⚠️ 警告: 文件夹已关联其他 syncID")
                                AppLogger.syncPrint("[SyncManager]   文件夹 ID: \(folder.id)")
                                AppLogger.syncPrint("[SyncManager]   当前 syncID: \(folder.syncID)")
                                AppLogger.syncPrint("[SyncManager]   已关联 syncID: \(existingSyncID)")
                            } else {
                                // 未知原因（理论上不应该发生）
                                AppLogger.syncPrint(
                                    "[SyncManager] ⚠️ 警告: syncID 注册失败（未知原因）: \(folder.syncID)")
                            }
                        }
                        AppLogger.syncPrint(
                            "[SyncManager]   - 文件夹: \(folder.localPath.path) (syncID: \(folder.syncID))"
                        )
                    }
                }
                self.folders = normalized
                // 加载持久化的删除记录（tombstones），防止重启后丢失删除信息导致文件被重新拉回
                self.deletedRecords = (try? StorageManager.shared.getDeletedRecords()) ?? [:]
            } catch {
                AppLogger.syncPrint("[SyncManager] ❌ 加载文件夹配置失败: \(error)")
                AppLogger.syncPrint("[SyncManager] 错误详情: \(error.localizedDescription)")
                self.folders = []
                self.deletedRecords = [:]
            }
        } else {
            // 测试环境：不从用户目录加载持久化文件夹/删除记录，保持每个测试用例起点干净
            self.folders = []
            self.deletedRecords = [:]
        }

        // 从快照恢复 lastKnownLocalPaths 和 lastKnownMetadata
        if !AppPaths.isRunningTests {
            restoreSnapshots()
        }

        // 初始化设备统计（自身始终在线）
        updateDeviceCounts()  // 这会同时更新 allDevicesValue

        // 初始化广播中的 syncID（在 P2PNode 启动后）
        Task { @MainActor in
            // 等待 P2PNode 启动完成
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.updateBroadcastSyncIDs()
        }

        // 初始化模块化组件
        folderMonitor = FolderMonitor(syncManager: self)
        folderStatistics = FolderStatistics(syncManager: self, folderMonitor: folderMonitor)
        p2pHandlers = P2PHandlers(syncManager: self, folderStatistics: folderStatistics)
        fileTransfer = FileTransfer(syncManager: self)
        syncEngine = SyncEngine(
            syncManager: self, fileTransfer: fileTransfer, folderStatistics: folderStatistics)

        // 监听 peerManager 的变化，同步更新 peers 数组和设备列表（用于兼容性和自动刷新）
        peersSyncTask = Task { @MainActor in
            // 定期同步 peers 数组和设备列表
            while !Task.isCancelled {
                let allPeers = peerManager.allPeers.map { $0.peerID }
                if self.peers != allPeers {
                    self.peers = allPeers
                }

                // 同时更新设备列表，确保 UI 自动刷新
                self.updateDeviceCounts()

                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 每秒同步一次
            }
        }

        peerDiscoveryTask = Task { @MainActor in
            p2pNode.onPeerDiscovered = { [weak self] peer, remoteSyncIDs in
                Task { @MainActor in
                    guard let self = self else { return }
                    let peerIDString = peer.b58String
                    guard !peerIDString.isEmpty else { return }

                    let wasNew = !self.peerManager.hasPeer(peerIDString)
                    // 不要覆盖已有的地址
                    // P2PNode.connectToDiscoveredPeer 已经添加了地址到 PeerManager
                    // 如果 peer 不存在，则添加（地址会在 connectToDiscoveredPeer 中添加）
                    // 如果 peer 已存在，则保留其现有地址，只更新在线状态
                    if wasNew {
                        // 新 peer，先添加（地址会在 connectToDiscoveredPeer 中添加）
                        // 这里使用空数组，因为地址会在 connectToDiscoveredPeer 中通过 addOrUpdatePeer 添加
                        self.peerManager.addOrUpdatePeer(peer, addresses: [])
                    }
                    // 更新在线状态（无论新旧 peer 都需要更新）
                    // 收到广播表示设备在线，更新 lastSeenTime 和在线状态
                    let wasOnline = self.peerManager.isOnline(peerIDString)
                    self.peerManager.updateOnlineStatus(peerIDString, isOnline: true)
                    self.peerManager.updateLastSeen(peerIDString)  // 更新最后可见时间

                    // 验证 lastSeenTime 是否已更新
                    if let peerInfo = self.peerManager.getPeer(peerIDString) {
                        let timeSinceUpdate = Date().timeIntervalSince(peerInfo.lastSeenTime)
                        if timeSinceUpdate > 1.0 {
                            AppLogger.syncPrint(
                                "[SyncManager] ⚠️ 警告: lastSeenTime 更新后时间差异常: \(timeSinceUpdate)秒")
                        }
                    }

                    // 收到广播时，无论状态是否变化，都更新设备统计和列表，确保同步
                    // 这样可以确保统计数据和"所有设备"列表始终保持一致
                    self.updateDeviceCounts()
                    if wasNew || !wasOnline {
                    }
                    // 减少收到广播的日志输出，只在状态变化时输出

                    // 利用广播中的 syncID 信息，只对匹配的 syncID 触发同步
                    let remoteSyncIDSet = Set(remoteSyncIDs)
                    let matchingFolders = self.folders.filter { folder in
                        remoteSyncIDSet.contains(folder.syncID)
                    }

                    if !matchingFolders.isEmpty {
                        AppLogger.syncPrint(
                            "[SyncManager] ✅ 发现匹配的 syncID: peer=\(peerIDString.prefix(12))..., 匹配数=\(matchingFolders.count)/\(self.folders.count)"
                        )
                    } else if !remoteSyncIDs.isEmpty {
                        AppLogger.syncPrint(
                            "[SyncManager] ℹ️ 远程设备没有匹配的 syncID: peer=\(peerIDString.prefix(12))..., 远程syncID数=\(remoteSyncIDs.count), 本地syncID数=\(self.folders.count)"
                        )
                    }

                    // 对于新对等点，只同步匹配的文件夹
                    // 对于已存在的对等点，只同步匹配且不在冷却期内的文件夹
                    Task { @MainActor in
                        // syncWithPeer 内部会处理对等点注册，这里直接调用即可
                        for folder in matchingFolders {
                            if wasNew {
                                // 新 peer，立即同步匹配的文件夹
                                self.syncWithPeer(peer: peer, folder: folder)
                            } else {
                                // 已存在的 peer，只同步不在冷却期内的文件夹
                                if self.shouldSyncFolderWithPeer(
                                    peerID: peerIDString, folder: folder)
                                {
                                    self.syncWithPeer(peer: peer, folder: folder)
                                }
                            }
                        }
                    }
                }
            }

            // 启动 P2P 节点，如果失败则记录详细错误
            do {
                try await p2pNode.start()
            } catch {
                AppLogger.syncPrint("[SyncManager] ❌ P2P 节点启动失败: \(error)")
                AppLogger.syncPrint("[SyncManager] 错误详情: \(error.localizedDescription)")
                if let nsError = error as NSError? {
                    AppLogger.syncPrint(
                        "[SyncManager] 错误域: \(nsError.domain), 错误码: \(nsError.code)")
                    AppLogger.syncPrint("[SyncManager] 用户信息: \(nsError.userInfo)")
                }
                // 继续执行，但 P2P 功能将不可用
                await MainActor.run {
                    for folder in self.folders {
                        self.updateFolderStatus(
                            folder.id, status: .error,
                            message: "P2P 节点启动失败: \(error.localizedDescription)")
                    }
                }
            }

            // Register P2P handlers
            p2pHandlers.setupP2PHandlers()

            // Start monitoring and announcing all folders
            await MainActor.run {
                for folder in folders {
                    startMonitoring(folder)
                    // 启动后自动统计文件数量（使用最新的 folder 对象）
                    if let latestFolder = folders.first(where: { $0.id == folder.id }) {
                        refreshFileCount(for: latestFolder)
                    }
                }
            }

            // 启动定期检查设备在线状态
            startPeerStatusMonitoring()

            // 启动后等待一段时间，然后对所有已注册的在线对等点触发同步
            // 这确保后启动的客户端能够自动同步文件
            Task { @MainActor in
                // 等待5秒，确保所有对等点都已发现并注册
                try? await Task.sleep(nanoseconds: 5_000_000_000)

                // 获取所有已注册的在线对等点
                let registeredPeers = peerManager.allPeers.filter { peerInfo in
                    p2pNode.registrationService.isRegistered(peerInfo.peerIDString)
                        && peerManager.isOnline(peerInfo.peerIDString)
                }

                if !registeredPeers.isEmpty {
                    // 对所有已注册的在线对等点触发同步
                    for folder in folders {
                        for peerInfo in registeredPeers {
                            syncWithPeer(peer: peerInfo.peerID, folder: folder)
                        }
                    }
                }
            }
        }
    }

    /// 标记某个 (syncID, path) 进入“同步写入冷却期”，用于忽略由同步落地导致的该路径 FSEvents。
    /// - Note: 既会在处理远端 PUT 写入时调用，也会在本地“下载落地写入”时调用（pull 同步）。
    func markSyncCooldown(syncID: String, path: String) {
        let key = "\(syncID):\(path)"
        syncWriteCooldown[key] = Date()
        // 顺带清理过期条目（避免字典无限增长）
        let cutoff = Date().addingTimeInterval(-max(10.0, syncCooldownDuration * 2))
        syncWriteCooldown = syncWriteCooldown.filter { $0.value > cutoff }
    }

    let ignorePatterns = [".DS_Store", ".git/", "node_modules/", ".build/", ".swiftpm/"]

    /// 更新广播中的 syncID 列表
    func updateBroadcastSyncIDs() {
        let syncIDs = folders.map { $0.syncID }
        p2pNode.updateBroadcastSyncIDs(syncIDs)
        AppLogger.syncPrint("[SyncManager] 📡 已更新广播 syncID: \(syncIDs.count) 个")
    }

    func setupP2PHandlers() {
        // 设置消息处理器
        p2pNode.messageHandler = { [weak self] request in
            guard let self = self else { return SyncResponse.error("Manager deallocated") }
            return try await self.handleSyncRequest(request)
        }
    }

    // MARK: - 本地变更记录
    // recordLocalChange 方法已移至 SyncManagerLocalChangeRecorder.swift

    // MARK: - 同步请求处理
    // handleSyncRequest 及相关方法已移至 SyncManagerRequestHandler.swift

    /// 从快照恢复 lastKnownLocalPaths 和 lastKnownMetadata
    private func restoreSnapshots() {
        Task.detached {
            do {
                let snapshots = try StorageManager.shared.loadAllSnapshots()
                await MainActor.run {
                    for snapshot in snapshots {
                        // 恢复路径集合
                        self.lastKnownLocalPaths[snapshot.syncID] = Set(snapshot.files.keys)

                        // 恢复元数据
                        var metadata: [String: FileMetadata] = [:]
                        for (path, fileSnapshot) in snapshot.files {
                            metadata[path] = FileMetadata(
                                hash: fileSnapshot.hash,
                                mtime: fileSnapshot.mtime,
                                vectorClock: fileSnapshot.vectorClock
                            )
                        }
                        self.lastKnownMetadata[snapshot.syncID] = metadata
                    }
                    AppLogger.syncPrint("[SyncManager] ✅ 已从快照恢复 \(snapshots.count) 个文件夹的状态")
                }
            } catch {
                AppLogger.syncPrint("[SyncManager] ⚠️ 从快照恢复状态失败: \(error)")
            }
        }
    }
}

/// 设备信息结构
public struct DeviceInfo: Identifiable, Equatable {
    public let id = UUID()
    public let peerID: String
    public let isLocal: Bool
    public let status: String

    public static func == (lhs: DeviceInfo, rhs: DeviceInfo) -> Bool {
        return lhs.peerID == rhs.peerID && lhs.isLocal == rhs.isLocal && lhs.status == rhs.status
    }
}
