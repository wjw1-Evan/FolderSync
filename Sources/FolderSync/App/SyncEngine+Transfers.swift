import Foundation

extension SyncEngine {

    /// 执行单个同步操作
    func executeAction(path: String, action: SyncDecisionEngine.SyncAction, session: SyncSession)
        async -> SyncLog.SyncedFileInfo?
    {
        guard let syncManager = syncManager else { return nil }

        switch action {
        case .download:
            return await downloadFile(path: path, session: session)

        case .upload:
            return await uploadFile(path: path, session: session)

        case .deleteLocal:
            let myPeerID = syncManager.p2pNode.peerID?.b58String ?? ""
            syncManager.deleteFileAtomically(path: path, syncID: session.syncID, peerID: myPeerID)
            return SyncLog.SyncedFileInfo(
                path: path,
                fileName: (path as NSString).lastPathComponent,
                folderName: session.folder.localPath.lastPathComponent,
                size: 0,
                operation: .delete
            )

        case .deleteRemote:
            do {
                _ = try await syncManager.p2pNode.sendRequest(
                    .deleteFiles(syncID: session.syncID, paths: [path: nil]), to: session.peerID)
                return SyncLog.SyncedFileInfo(
                    path: path,
                    fileName: (path as NSString).lastPathComponent,
                    folderName: session.folder.localPath.lastPathComponent,
                    size: 0,
                    operation: .delete
                )
            } catch {
                AppLogger.syncPrint("[SyncEngine] ❌ 远程删除失败: \(path) - \(error)")
                return nil
            }

        case .conflict:
            return await downloadConflictFile(path: path, session: session)

        case .skip, .uncertain:
            return nil
        }
    }

    /// 下载文件逻辑
    private func downloadFile(path: String, session: SyncSession) async -> SyncLog.SyncedFileInfo? {
        guard let remoteMeta = session.remoteStates[path]?.metadata, let ft = fileTransfer else {
            return nil
        }

        let localURL = session.folder.localPath.appendingPathComponent(path)
        let fm = FileManager.default

        // 处理目录
        if remoteMeta.isDirectory {
            try? fm.createDirectory(at: localURL, withIntermediateDirectories: true)
            if let vc = remoteMeta.vectorClock {
                VectorClockManager.saveVectorClock(
                    folderID: session.folderID, syncID: session.syncID, path: path, vc: vc)
            }
            return SyncLog.SyncedFileInfo(
                path: path,
                fileName: (path as NSString).lastPathComponent,
                folderName: session.folder.localPath.lastPathComponent,
                size: 0,
                operation: .create
            )
        }

        // 处理文件下载
        do {
            if remoteMeta.size >= 256 * 1024 {  // chunkSyncThreshold
                return try await ft.downloadFileWithChunks(
                    folder: session.folder,
                    path: path,
                    remoteMeta: remoteMeta,
                    peerID: session.peerID
                )
            } else {
                return try await ft.downloadFileFull(
                    folder: session.folder,
                    path: path,
                    remoteMeta: remoteMeta,
                    peerID: session.peerID
                )
            }
        } catch {
            AppLogger.syncPrint("[SyncEngine] ❌ 下载文件失败: \(path) - \(error)")
            return nil
        }
    }

    /// 上传文件逻辑
    private func uploadFile(path: String, session: SyncSession) async -> SyncLog.SyncedFileInfo? {
        guard let localMeta = session.localMetadata?[path], let ft = fileTransfer else {
            return nil
        }

        do {
            if localMeta.size >= 256 * 1024 {  // chunkSyncThreshold
                return try await ft.uploadFileWithChunks(
                    folder: session.folder,
                    path: path,
                    localMeta: localMeta,
                    peerID: session.peerID
                )
            } else {
                return try await ft.uploadFileFull(
                    folder: session.folder,
                    path: path,
                    localMeta: localMeta,
                    peerID: session.peerID
                )
            }
        } catch {
            AppLogger.syncPrint("[SyncEngine] ❌ 上传文件失败: \(path) - \(error)")
            return nil
        }
    }

    /// 处理冲突文件下载
    private func downloadConflictFile(path: String, session: SyncSession) async -> SyncLog
        .SyncedFileInfo?
    {
        guard let syncManager = syncManager, session.remoteStates[path]?.metadata != nil
        else { return nil }

        let fileName = (path as NSString).lastPathComponent
        let timestamp = Int(Date().timeIntervalSince1970)
        let conflictName = "\(fileName).conflict.\(session.peerID.prefix(8)).\(timestamp)"
        let pathDir = (path as NSString).deletingLastPathComponent
        let remoteConflictPath = pathDir.isEmpty ? conflictName : "\(pathDir)/\(conflictName)"

        do {
            // 注意：这里简化为直接请求数据并保存为本地冲突文件
            let dataRes = try await syncManager.p2pNode.sendRequest(
                .getFileData(syncID: session.syncID, path: path), to: session.peerID)
            guard case .fileData(_, _, let data) = dataRes else { return nil }

            let parentURL = session.folder.localPath.appendingPathComponent(pathDir)
            let conflictURL = parentURL.appendingPathComponent(conflictName)

            try FileManager.default.createDirectory(
                at: parentURL, withIntermediateDirectories: true)
            try data.write(to: conflictURL)

            // 记录冲突
            let cf = ConflictFile(
                syncID: session.syncID,
                relativePath: path,
                conflictPath: remoteConflictPath,
                remotePeerID: session.peerID
            )
            try? StorageManager.shared.addConflict(cf)

            return SyncLog.SyncedFileInfo(
                path: path,
                fileName: (path as NSString).lastPathComponent,
                folderName: session.folder.localPath.lastPathComponent,
                size: Int64(data.count),
                operation: .create
            )
        } catch {
            AppLogger.syncPrint("[SyncEngine] ❌ 处理冲突文件失败: \(path) - \(error)")
            return nil
        }
    }
}
