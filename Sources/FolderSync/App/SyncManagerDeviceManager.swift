import Foundation

/// 设备管理扩展
/// 负责设备统计、在线状态检查和设备列表更新
extension SyncManager {
    /// 启动定期检查设备在线状态
    func startPeerStatusMonitoring() {
        peerStatusCheckTask?.cancel()
        peerStatusCheckTask = Task { [weak self] in
            // 首次等待 30 秒，给设备足够时间完成连接和注册
            try? await Task.sleep(nanoseconds: 30_000_000_000)

            while !Task.isCancelled {
                guard let self = self else { break }
                await self.checkAllPeersOnlineStatus()
                // 每 10 秒检查一次，更快检测离线设备
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    /// 检查所有对等点的在线状态
    /// 简化逻辑：仅使用收到的广播判断peer有效性
    func checkAllPeersOnlineStatus() async {
        // 注意：SyncManager 是 @MainActor，所以可以直接访问 peerManager
        let peersToCheck = peerManager.allPeers
        guard !peersToCheck.isEmpty else {
            // 如果没有对等点，重置设备计数（只保留自身）
            onlineDeviceCountValue = 1
            offlineDeviceCountValue = 0
            // 同时更新所有文件夹的 peerCount
            for folder in folders {
                updatePeerCount(for: folder.syncID)
            }
            return
        }

        var statusChanged = false

        for peerInfo in peersToCheck {
            let peerIDString = peerInfo.peerIDString

            // 重新获取最新的 peerInfo（可能在检查过程中收到了新广播）
            let currentPeerInfo = peerManager.getPeer(peerIDString)
            guard let currentPeer = currentPeerInfo else {
                AppLogger.syncPrint("[SyncManager] ⚠️ Peer 不存在，跳过检查: \(peerIDString.prefix(12))...")
                continue
            }

            // 简化逻辑：仅使用广播判断有效性
            // 检查最近是否收到过广播（30秒内）
            // 广播间隔是1秒，检查间隔是10秒，考虑到UDP可能丢包，设置30秒窗口
            let timeSinceLastSeen = Date().timeIntervalSince(currentPeer.lastSeenTime)
            let isOnline = timeSinceLastSeen < 30.0  // 30秒内收到广播则认为在线

            let wasOnline = peerManager.isOnline(peerIDString)

            // 简化逻辑：无法访问的peer直接删除（30秒内没有收到广播）
            if !isOnline {
                // 删除无法访问的 peer（30秒内未收到广播）
                // 从所有syncID中移除该peer
                for folder in folders {
                    removeFolderPeer(folder.syncID, peerID: peerIDString)
                }
                // 从PeerManager中删除
                peerManager.removePeer(peerIDString)
                statusChanged = true
            } else if isOnline != wasOnline {
                // 状态变化，更新在线状态
                statusChanged = true
                peerManager.updateOnlineStatus(peerIDString, isOnline: true)
            }
        }

        if statusChanged {
            updateDeviceCounts()
        }
    }

    /// 获取总设备数量（包括自身）
    var totalDeviceCount: Int {
        peerManager.allPeers.count + 1  // 包括自身
    }

    /// 在线设备数量（包括自身）
    var onlineDeviceCount: Int {
        return onlineDeviceCountValue
    }

    /// 离线设备数量
    var offlineDeviceCount: Int {
        return offlineDeviceCountValue
    }

    /// 更新设备统计（内部方法）
    /// 简化逻辑：无法访问的设备会被直接删除，所以只统计在线设备
    func updateDeviceCounts() {
        // 先更新设备列表
        updateAllDevices()

        // 简化逻辑：只统计在线设备（无法访问的设备会被直接删除）
        let deviceListOnline = allDevicesValue.filter { $0.status == "在线" && !$0.isLocal }.count

        let oldOnline = onlineDeviceCountValue
        let oldOffline = offlineDeviceCountValue

        onlineDeviceCountValue = deviceListOnline + 1  // 包括自身
        offlineDeviceCountValue = 0  // 简化：无法访问的设备会被删除，所以离线设备数始终为0

        // 如果计数发生变化，输出日志
        if oldOnline != onlineDeviceCountValue || oldOffline != offlineDeviceCountValue {
            AppLogger.syncPrint(
                "[SyncManager] 📊 设备计数已更新: 在线=\(onlineDeviceCountValue) (之前: \(oldOnline)), 离线=\(offlineDeviceCountValue) (之前: \(oldOffline))"
            )
        }

        // 更新所有文件夹的在线设备统计
        for folder in folders {
            updatePeerCount(for: folder.syncID)
        }
    }

    /// 获取所有设备列表（包括自身）
    /// 简化逻辑：只显示在线设备，无法访问的设备会被直接删除
    var allDevices: [DeviceInfo] {
        return allDevicesValue
    }

    /// 更新设备列表（内部方法）
    /// 简化逻辑：只显示在线设备，无法访问的设备会被直接删除
    func updateAllDevices() {
        var devices: [DeviceInfo] = []

        // 添加自身
        if let myPeerID = p2pNode.peerID?.b58String {
            devices.append(
                DeviceInfo(
                    peerID: myPeerID,
                    isLocal: true,
                    status: "在线"
                ))
        }

        // 简化逻辑：只添加在线设备（无法访问的设备会被直接删除）
        for peerInfo in peerManager.allPeers {
            let status = peerManager.getDeviceStatus(peerInfo.peerIDString)
            // 只显示在线设备
            if status == .online {
                devices.append(
                    DeviceInfo(
                        peerID: peerInfo.peerIDString,
                        isLocal: false,
                        status: "在线"
                    ))
            }
        }

        // 只有当列表真正变化时才更新，避免不必要的 UI 刷新
        if devices != allDevicesValue {
            allDevicesValue = devices
        }
    }
}
