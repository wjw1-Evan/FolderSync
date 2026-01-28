import Foundation

/// 同步协调扩展
/// 负责同步触发、对等点同步和请求发送
extension SyncManager {
    func syncWithPeer(peer: PeerID, folder: SyncFolder) {
        syncEngine.syncWithPeer(peer: peer, folder: folder)
    }

    /// 统一的请求函数 - 使用原生 TCP
    func sendSyncRequest(
        _ message: SyncRequest,
        to peer: PeerID,
        peerID: String,
        timeout: TimeInterval = 90.0,
        maxRetries: Int = 3,
        folder: SyncFolder? = nil
    ) async throws -> SyncResponse {
        // 获取对等点地址
        let peerAddresses = await MainActor.run {
            return p2pNode.peerManager.getAddresses(for: peer.b58String)
        }

        // 从地址中提取第一个可用的 IP:Port 地址
        let addressStrings = peerAddresses.map { $0.description }
        guard let address = AddressConverter.extractFirstAddress(from: addressStrings) else {
            print("[SyncManager] 🗑️ [DEBUG] 删除无法访问的peer（无可用地址）: \(peerID.prefix(12))...")
            // 简化逻辑：无法访问的peer直接删除
            await MainActor.run {
                // 从所有syncID中移除该peer
                for folder in self.folders {
                    self.removeFolderPeer(folder.syncID, peerID: peerID)
                }
                // 从PeerManager中删除
                self.peerManager.removePeer(peerID)
            }
            throw NSError(
                domain: "SyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "对等点无可用地址"])
        }

        // 验证提取的地址
        let addressComponents = address.split(separator: ":")
        guard addressComponents.count == 2,
            let extractedIP = String(addressComponents[0]).removingPercentEncoding,
            let extractedPort = UInt16(String(addressComponents[1])),
            extractedPort > 0,
            extractedPort <= 65535,
            !extractedIP.isEmpty,
            extractedIP != "0.0.0.0"
        else {
            print("[SyncManager] ❌ [sendSyncRequest] 地址格式验证失败: \(address)")
            throw NSError(
                domain: "SyncManager", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "地址格式无效: \(address)"])
        }

        // 使用原生 TCP
        do {
            return try await p2pNode.nativeNetwork.sendRequest(
                message,
                to: address,
                timeout: timeout,
                maxRetries: maxRetries
            ) as SyncResponse
        } catch {
            // 简化逻辑：仅使用广播判断peer有效性，请求失败不删除peer
            // 如果peer仍在发送广播，说明它是在线的，请求失败可能是临时网络问题
            // peer的有效性由广播时间戳判断，不在请求过程中删除peer
            throw error
        }
    }

    /// 检查是否应该为特定对等点和文件夹触发同步
    /// 避免频繁触发不必要的同步（比如在短时间内多次收到广播）
    /// - Parameters:
    ///   - peerID: 对等点 ID
    ///   - folder: 文件夹
    /// - Returns: 是否应该触发同步
    func shouldSyncFolderWithPeer(peerID: String, folder: SyncFolder) -> Bool {
        let cooldownKey = "\(peerID):\(folder.syncID)"
        if let lastSyncTime = peerSyncCooldown[cooldownKey] {
            let timeSinceLastSync = Date().timeIntervalSince(lastSyncTime)
            // 如果该 peer-folder 对在最近30秒内已经同步过，阻止同步
            if timeSinceLastSync < peerSyncCooldownDuration {
                return false
            }
        }
        // 不在冷却期内，允许同步
        return true
    }

    /// 检查是否应该为对等点触发同步（用于判断是否有任何文件夹需要同步）
    /// 避免频繁触发不必要的同步（比如在短时间内多次收到广播）
    /// - Parameter peerID: 对等点 ID
    /// - Returns: 是否应该触发同步
    func shouldTriggerSyncForPeer(peerID: String) -> Bool {
        // 检查该对等点与所有文件夹的同步冷却时间
        // 如果该对等点与任何文件夹不在冷却期内，允许触发同步（因为至少有一个文件夹需要同步）
        // 只有当该对等点与所有文件夹都在冷却期内时，才阻止同步
        guard !folders.isEmpty else {
            return true
        }

        // 检查是否所有文件夹都在冷却期内
        var allInCooldown = true
        for folder in folders {
            let cooldownKey = "\(peerID):\(folder.syncID)"
            if let lastSyncTime = peerSyncCooldown[cooldownKey] {
                let timeSinceLastSync = Date().timeIntervalSince(lastSyncTime)
                // 如果该文件夹在最近30秒内已经同步过，继续检查下一个
                if timeSinceLastSync < peerSyncCooldownDuration {
                    continue
                }
            }
            // 如果该文件夹不在冷却期内，说明至少有一个文件夹需要同步
            allInCooldown = false
            break
        }

        // 如果所有文件夹都在冷却期内，阻止同步；否则允许同步
        return !allInCooldown
    }

    func triggerSync(for folder: SyncFolder) {
        // 检查是否有同步正在进行，避免重复触发
        // 注意：SyncManager 是 @MainActor，所以可以直接访问 syncInProgress
        let allPeers = peerManager.allPeers

        let hasSyncInProgress = allPeers.contains { peerInfo in
            let syncKey = "\(folder.syncID):\(peerInfo.peerIDString)"
            return syncInProgress.contains(syncKey)
        }

        if hasSyncInProgress {
            return
        }

        // 先更新状态，但不影响统计值（保留现有统计值）
        updateFolderStatus(folder.id, status: .syncing, message: "Scanning local files...")

        Task {
            // 1. Calculate the current state
            // 注意：这里计算状态是为了同步，统计更新应该通过 refreshFileCount 进行
            // 但为了同步需要，我们也需要更新统计值
            // 注意：这里更新统计值是为了同步开始时显示最新状态
            // SyncEngine 同步完成后也会更新统计值，但那是同步后的最终状态
            let (_, metadata, folderCount, totalSize) = await calculateFullState(for: folder)

            await MainActor.run {
                if let index = self.folders.firstIndex(where: { $0.id == folder.id }) {
                    // 创建新的文件夹对象以触发 @Published 更新
                    // 重要：原子性更新，一次性设置所有统计值，避免中间状态
                    var updatedFolder = self.folders[index]

                    // 直接使用新计算的值（即使为0也是有效值）
                    // 原子性更新：一次性设置所有统计值，避免 UI 看到中间状态
                    updatedFolder.fileCount = metadata.count
                    updatedFolder.folderCount = folderCount
                    updatedFolder.totalSize = totalSize

                    // 一次性替换，确保 UI 看到的是完整的新值
                    self.folders[index] = updatedFolder
                    // 手动触发 objectWillChange 以确保 UI 更新
                    self.objectWillChange.send()
                    // 持久化保存统计信息更新
                    do {
                        try StorageManager.shared.saveFolder(updatedFolder)
                    } catch {
                        print("[SyncManager] ⚠️ 无法保存文件夹统计信息更新: \(error)")
                    }
                }
            }

            // 2. Try sync with all registered peers (多点同步)
            // 需要在 MainActor 上访问 peerManager 和 registrationService
            let registeredPeers = await MainActor.run {
                let allPeers = self.peerManager.allPeers
                // 过滤出已注册且在线的对等点（离线设备不进行同步）
                return allPeers.filter { peerInfo in
                    self.p2pNode.registrationService.isRegistered(peerInfo.peerIDString)
                        && self.peerManager.isOnline(peerInfo.peerIDString)
                }
            }

            if registeredPeers.isEmpty {
                await MainActor.run {
                    self.updateFolderStatus(
                        folder.id, status: .synced, message: "等待发现对等点...", progress: 0.0)
                }
            } else {
                // 多点同步：同时向所有已注册且在线的对等点同步
                for peerInfo in registeredPeers {
                    syncWithPeer(peer: peerInfo.peerID, folder: folder)
                }
                
                // 定期检查同步状态，如果所有同步都完成但状态仍然是 .syncing，重置状态
                // 这样可以避免因为所有 peer 都失败而导致状态一直卡在 .syncing
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let maxWaitTime = 60.0 // 最多等待60秒
                    let checkInterval = 2.0 // 每2秒检查一次
                    let startTime = Date()
                    
                    while Date().timeIntervalSince(startTime) < maxWaitTime {
                        try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
                        
                        // 检查是否所有 peer 的同步都已完成
                        let allSyncCompleted = registeredPeers.allSatisfy { peerInfo in
                            let syncKey = "\(folder.syncID):\(peerInfo.peerIDString)"
                            return !self.syncInProgress.contains(syncKey)
                        }
                        
                        if allSyncCompleted {
                            // 所有同步都完成，检查状态
                            if let index = self.folders.firstIndex(where: { $0.id == folder.id }) {
                                let currentFolder = self.folders[index]
                                if currentFolder.status == .syncing {
                                    print("[SyncManager] 🔄 所有同步已完成但状态仍为 .syncing，重置状态: \(folder.syncID)")
                                    self.updateFolderStatus(
                                        folder.id, status: .synced, message: "同步完成", progress: 1.0)
                                }
                            }
                            // 状态已重置，退出循环
                            break
                        }
                    }
                }
            }
        }
    }
}
