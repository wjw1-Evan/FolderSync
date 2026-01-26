import SwiftUI

struct MainDashboard: View {
    @EnvironmentObject var syncManager: SyncManager
    @State private var showingAddFolder = false
    @State private var showingConflictCenter = false
    @State private var showingSyncHistory = false
    @State private var showingAllPeers = false
    @State private var conflictCount: Int = 0
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        // 网络状态卡片
                        HStack(spacing: 16) {
                            // 上传速度
                            HStack(spacing: 6) {
                                Image(systemName: syncManager.uploadSpeedBytesPerSec > 0 ? "arrow.up.circle.fill" : "arrow.up.circle")
                                    .foregroundStyle(syncManager.uploadSpeedBytesPerSec > 0 ? .blue : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(LocalizedString.upload)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(byteRate(syncManager.uploadSpeedBytesPerSec))
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                }
                            }
                            
                            Divider()
                                .frame(height: 30)
                            
                            // 下载速度
                            HStack(spacing: 6) {
                                Image(systemName: syncManager.downloadSpeedBytesPerSec > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                                    .foregroundStyle(syncManager.downloadSpeedBytesPerSec > 0 ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(LocalizedString.download)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(byteRate(syncManager.downloadSpeedBytesPerSec))
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                }
                            }
                            
                            Spacer()
                            
                            // 设备状态按钮
                            Button {
                                showingAllPeers = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "laptopcomputer.and.iphone")
                                        .font(.caption)
                                    if syncManager.offlineDeviceCount > 0 {
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(.green)
                                                .frame(width: 6, height: 6)
                                            Text("\(syncManager.onlineDeviceCount)")
                                                .foregroundStyle(.green)
                                            Text("•")
                                                .foregroundStyle(.secondary)
                                            Circle()
                                                .fill(.red)
                                                .frame(width: 6, height: 6)
                                            Text("\(syncManager.offlineDeviceCount)")
                                                .foregroundStyle(.red)
                                        }
                                    } else {
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(.green)
                                                .frame(width: 6, height: 6)
                                            Text("\(syncManager.onlineDeviceCount)\(LocalizedString.onlineSuffix)")
                                                .foregroundStyle(.green)
                                        }
                                    }
                                }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                } header: { 
                    Text(LocalizedString.status)
                }
                Section(LocalizedString.syncFolders) {
                    ForEach(syncManager.folders) { folder in
                        FolderRow(folderID: folder.id)
                            .environmentObject(syncManager)
                    }
                    if syncManager.folders.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary.opacity(0.5))
                            Text(LocalizedString.noFoldersAdded)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text(LocalizedString.tapToAddFolder)
                                .font(.caption)
                                .foregroundStyle(.secondary.opacity(0.8))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                }
            }
            .listStyle(.inset)
            .navigationTitle(LocalizedString.dashboard)
            .sheet(isPresented: $showingAllPeers) {
                AllPeersListView()
                    .environmentObject(syncManager)
            }
            .refreshable {
                await refreshData()
            }
            .onAppear {
                // 设置窗口标识符，方便检查窗口是否已存在
                DispatchQueue.main.async {
                    if let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow || $0.isMainWindow }) {
                        window.identifier = NSUserInterfaceItemIdentifier("main")
                        window.title = LocalizedString.dashboard
                    }
                }
                updateConflictCount()
            }
            .onChange(of: syncManager.folders) { _, _ in
                updateConflictCount()
            }
            .task {
                // 定期更新冲突数量
                while !Task.isCancelled {
                    updateConflictCount()
                    try? await Task.sleep(nanoseconds: 5_000_000_000) // 每5秒更新一次
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddFolder = true
                    } label: {
                        Label(LocalizedString.addFolder, systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingConflictCenter = true
                    } label: {
                        HStack(spacing: 4) {
                            Label(LocalizedString.conflictCenter, systemImage: "exclamationmark.triangle")
                            if conflictCount > 0 {
                                Text("\(conflictCount)")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.red)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSyncHistory = true
                    } label: {
                        Label(LocalizedString.syncHistory, systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            .sheet(isPresented: $showingAddFolder) {
                AddFolderView()
            }
            .sheet(isPresented: $showingConflictCenter) {
                ConflictCenter()
                    .environmentObject(syncManager)
            }
            .sheet(isPresented: $showingSyncHistory) {
                SyncHistoryView()
                    .environmentObject(syncManager)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
    
    private func byteRate(_ bytesPerSec: Double) -> String {
        guard bytesPerSec > 0 else {
            return "0 KB/s"
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        let formatted = formatter.string(fromByteCount: Int64(bytesPerSec))
        return "\(formatted)/s"
    }
    
    private func byteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func updateConflictCount() {
        Task { @MainActor in
            let conflicts = (try? StorageManager.shared.getAllConflicts(unresolvedOnly: true)) ?? []
            conflictCount = conflicts.count
        }
    }
    
    private func refreshData() async {
        updateConflictCount()
        // 可以在这里添加其他刷新逻辑
    }
}

struct FolderRow: View {
    @EnvironmentObject var syncManager: SyncManager
    let folderID: UUID
    @State private var showingPeerList = false
    @State private var showingExcludeRules = false
    @State private var isHovered = false
    @State private var showCopySuccess = false
    @State private var showingRemoveConfirmation = false
    
    // 从 syncManager 中获取最新的 folder 对象
    private var folder: SyncFolder? {
        syncManager.folders.first(where: { $0.id == folderID })
    }
    
    var body: some View {
        Group {
            if let folder = folder {
                ZStack(alignment: .leading) {
                    // 进度条背景（在同步时显示，只在有明确的同步消息时显示，避免统计更新时的闪烁）
                    // 注意：只在有同步消息时显示进度条，避免仅因为状态为 syncing 就显示
                    if folder.status == .syncing, let message = folder.lastSyncMessage, !message.isEmpty {
                        GeometryReader { geometry in
                            let progress = max(folder.syncProgress, 0.0)
                            let minWidth = geometry.size.width * 0.02 // 最小宽度 2%，表示正在同步
                            let progressWidth = geometry.size.width * progress
                            Rectangle()
                                .fill(Color.blue.opacity(0.15))
                                .frame(width: max(progressWidth, minWidth))
                                // 只在 progress > 0 时使用动画，避免统计更新时的闪烁
                                .animation(progress > 0 ? .linear(duration: 0.2) : nil, value: folder.syncProgress)
                        }
                    }
                    
                    // 文件夹内容
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            // 文件夹图标
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                                .font(.title2)
                                .frame(width: 32)
                            
                            // 文件夹信息
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(folder.localPath.lastPathComponent)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Spacer()
                                    StatusBadge(status: folder.status)
                                }
                                
                                // 路径和同步ID（同一行）
                                HStack(spacing: 8) {
                                    // 路径（左侧，可截断）
                                    Text(folder.localPath.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    
                                    Spacer()
                                    
                                    // 同步ID（右侧）
                                    HStack(spacing: 4) {
                                        Text(LocalizedString.idLabel)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(folder.syncID)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.primary)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.secondary.opacity(0.1))
                                            .cornerRadius(3)
                                        
                                        Button {
                                            let pasteboard = NSPasteboard.general
                                            pasteboard.clearContents()
                                            pasteboard.setString(folder.syncID, forType: .string)
                                            
                                            // 显示复制成功提示
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                showCopySuccess = true
                                            }
                                            
                                            // 2秒后隐藏提示
                                            Task {
                                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                                withAnimation(.easeInOut(duration: 0.2)) {
                                                    showCopySuccess = false
                                                }
                                            }
                                        } label: {
                                            Group {
                                                if showCopySuccess {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .foregroundStyle(.green)
                                                } else {
                                                    Image(systemName: "doc.on.doc")
                                                        .foregroundStyle(.blue)
                                                }
                                            }
                                            .font(.caption2)
                                            .transition(.scale.combined(with: .opacity))
                                        }
                                        .buttonStyle(.plain)
                                        .help(showCopySuccess ? LocalizedString.copied : LocalizedString.copySyncIDHelp(folder.syncID))
                                    }
                                }
                                
                                // 统计信息
                                HStack(spacing: 12) {
                                    // 文件数量（如果已统计则显示，否则显示占位符）
                                    if let fileCount = folder.fileCount {
                                        Label("\(fileCount)\(LocalizedString.files)", systemImage: "doc")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Label(LocalizedString.counting, systemImage: "doc")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary.opacity(0.6))
                                    }
                                    
                                    // 文件夹数量（如果已统计且大于0则显示）
                                    if let folderCount = folder.folderCount, folderCount > 0 {
                                        Label("\(folderCount)\(LocalizedString.folders)", systemImage: "folder")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    // 总大小（如果已统计且大于0则显示）
                                    if let totalSize = folder.totalSize, totalSize > 0 {
                                        Label(formatByteCount(totalSize), systemImage: "internaldrive")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    // 设备数量
                                    if folder.peerCount > 0 {
                                        Button {
                                            showingPeerList = true
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "laptopcomputer.and.iphone")
                                                Text("\(folder.peerCount)\(LocalizedString.devices)")
                                            }
                                            .font(.caption2)
                                            .foregroundStyle(.blue)
                                        }
                                        .buttonStyle(.plain)
                                        .popover(isPresented: $showingPeerList) {
                                            PeerListView(syncID: folder.syncID)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                // folder 不存在时的占位视图
                EmptyView()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            Group {
                if isHovered {
                    Color.secondary.opacity(0.05)
                } else {
                    Color.clear
                }
            }
        )
        .cornerRadius(8)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            if let folder = folder {
                Button {
                    NSWorkspace.shared.open(folder.localPath)
                } label: {
                    Label(LocalizedString.openInFinder, systemImage: "folder")
                }
                
                Divider()
                
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(folder.syncID, forType: .string)
                    
                    // 显示复制成功提示
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showCopySuccess = true
                    }
                    
                    // 2秒后隐藏提示
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showCopySuccess = false
                        }
                    }
                } label: {
                    Label(LocalizedString.copySyncID, systemImage: "doc.on.doc")
                }
                
                Button {
                    showingExcludeRules = true
                } label: {
                    Label(LocalizedString.excludeRules, systemImage: "line.3.horizontal.decrease.circle")
                }
                
                Divider()
                
                Button(role: .destructive) {
                    showingRemoveConfirmation = true
                } label: {
                    Label(LocalizedString.removeFolder, systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $showingExcludeRules) {
            if let folder = folder {
                ExcludeRulesView(folder: folder)
                    .environmentObject(syncManager)
            }
        }
        .confirmationDialog(
            LocalizedString.confirmRemoveFolder,
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            if let folder = folder {
                Button(LocalizedString.remove, role: .destructive) {
                    syncManager.removeFolder(folder)
                }
                Button(LocalizedString.cancel, role: .cancel) {}
            }
        } message: {
            if let folder = folder {
                Text(String(format: LocalizedString.confirmRemoveFolderMessage, folder.localPath.lastPathComponent))
            }
        }
    }
    
    private func formatByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct StatusBadge: View {
    let status: SyncStatus
    
    var body: some View {
        Text(LocalizedString.syncStatus(status).uppercased())
            .font(.caption2)
            .fontWeight(.bold)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(backgroundColor.opacity(0.1))
            .foregroundStyle(backgroundColor)
            .clipShape(Capsule())
    }
    
    var backgroundColor: Color {
        switch status {
        case .synced: return .green
        case .syncing: return .blue
        case .error: return .red
        case .paused: return .orange
        }
    }
}

struct AddFolderView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var syncManager: SyncManager
    @State private var selectedPath: URL?
    @State private var syncID: String = ""
    @State private var errorMessage: String?
    @State private var isDragging = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text(LocalizedString.addSyncFolder)
                .font(.title2)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizedString.localFolderPath)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                // 支持拖拽的文件夹选择区域
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isDragging ? Color.blue.opacity(0.1) : Color.secondary.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isDragging ? Color.blue : Color.clear, lineWidth: 2)
                        )
                    
                    if let path = selectedPath {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(path.lastPathComponent)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(path.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                selectedPath = nil
                                errorMessage = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding()
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text(LocalizedString.dragFolderHere)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                }
                .frame(height: selectedPath != nil ? 80 : 120)
                .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
                    handleDrop(providers: providers)
                }
                .onTapGesture {
                    selectFolder()
                }
                
                if let error = errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
                }
            }
            
            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizedString.syncID)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                HStack(spacing: 8) {
                    TextField(LocalizedString.enterSyncID, text: $syncID)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: syncID) { _, newValue in
                            validateSyncID(newValue)
                        }
                    
                    Button {
                        syncID = generateRandomSyncID()
                        validateSyncID(syncID)
                    } label: {
                        Image(systemName: "dice.fill")
                            .padding(8)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(6)
                    }
                    .help(LocalizedString.generateSyncID)
                }
                
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                    Text(LocalizedString.syncIDDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
            }
            
            // 设备状态
            HStack {
                if !syncManager.peers.isEmpty {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text(LocalizedString.devicesDiscovered(syncManager.peers.count))
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                } else {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                        Text(LocalizedString.waitingForDevices)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(6)
            
            Divider()
            
            HStack {
                Button(LocalizedString.cancel) { 
                    dismiss() 
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button {
                    addFolder()
                } label: {
                    Text(LocalizedString.addSync)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedPath == nil || syncID.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
    
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            validateAndSetPath(url)
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }
            
            DispatchQueue.main.async {
                validateAndSetPath(url)
            }
        }
        
        return true
    }
    
    private func validateAndSetPath(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            errorMessage = LocalizedString.selectValidFolder
            return
        }
        
        // 检查是否已经添加过
        if syncManager.folders.contains(where: { $0.localPath == url }) {
            errorMessage = LocalizedString.folderAlreadyAdded
            return
        }
        
        // 检查是否是其他同步文件夹的子目录
        for folder in syncManager.folders {
            if url.path.hasPrefix(folder.localPath.path + "/") {
                errorMessage = LocalizedString.cannotAddSubdirectory
                return
            }
        }
        
        selectedPath = url
        errorMessage = nil
    }
    
    private func validateSyncID(_ id: String) {
        // 基本验证：不能为空，长度合理
        if id.isEmpty {
            return
        }
        
        if id.count < 8 {
            errorMessage = LocalizedString.syncIDMinLength
            return
        }
        
        errorMessage = nil
    }
    
    private func addFolder() {
        guard let path = selectedPath, !syncID.isEmpty else { return }
        
        // 再次验证
        validateAndSetPath(path)
        validateSyncID(syncID)
        
        guard errorMessage == nil else {
            return
        }
        
        let newFolder = SyncFolder(syncID: syncID, localPath: path, mode: .twoWay)
        syncManager.addFolder(newFolder)
        dismiss()
    }
    
    private func generateRandomSyncID() -> String {
        return SyncIDManager.generateSyncID()
    }
}


/// 所有设备列表视图（包括自身）
struct AllPeersListView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var syncManager: SyncManager
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(syncManager.allDevices) { device in
                    HStack(spacing: 12) {
                        Image(systemName: device.isLocal ? "laptopcomputer" : "laptopcomputer.and.iphone")
                            .foregroundStyle(device.isLocal ? .blue : .green)
                            .font(.title3)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(device.isLocal ? LocalizedString.local : LocalizedString.remoteDevice)
                                    .font(.headline)
                                if device.isLocal {
                                    Text(LocalizedString.me)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            
                            Text(device.peerID)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(device.status == LocalizedString.online ? .green : .red)
                                    .frame(width: 6, height: 6)
                                Text(device.status)
                                    .font(.caption2)
                                    .foregroundStyle(device.status == LocalizedString.online ? .green : .red)
                                if !device.isLocal {
                                    Text("•")
                                        .foregroundStyle(.secondary)
                                    Label(LocalizedString.direct, systemImage: "network")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "laptopcomputer.and.iphone")
                            .foregroundStyle(.blue)
                            .font(.title3)
                        Text(LocalizedString.allDevices)
                            .font(.headline)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedString.close) {
                        dismiss()
                    }
                }
            }
            .navigationTitle("") // 空标题，使用 toolbar principal 显示带图标的标题
        }
        .frame(width: 500, height: 400)
    }
}

struct PeerListView: View {
    @EnvironmentObject var syncManager: SyncManager
    let syncID: String
    
    // 只获取在线的 peer
    var peers: [String] {
        let allPeerIDs = syncManager.syncIDManager.getPeers(for: syncID)
        // 只返回在线的 peer
        return allPeerIDs.filter { peerID in
            syncManager.peerManager.isOnline(peerID)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedString.onlineDevices)
                .font(.headline)
                .padding(.bottom, 4)
            
            if peers.isEmpty {
                Text(LocalizedString.noOnlineDevices)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(peers, id: \.self) { peerID in
                            HStack {
                                Image(systemName: "laptopcomputer")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peerID)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    HStack(spacing: 6) {
                                        Label(LocalizedString.direct, systemImage: "network")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text("•")
                                            .foregroundStyle(.secondary)
                                        Text(LocalizedString.online)
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    }
                                }
                                Spacer()
                                Circle()
                                    .fill(.green)
                                    .frame(width: 8, height: 8)
                            }
                            .padding(8)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 320, height: 260)
    }
}

