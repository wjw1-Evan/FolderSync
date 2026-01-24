import SwiftUI

struct MainDashboard: View {
    @EnvironmentObject var syncManager: SyncManager
    @State private var showingAddFolder = false
    @State private var showingConflictCenter = false
    @State private var showingSyncHistory = false
    @State private var showingAllPeers = false
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        Label("↑ \(byteRate(syncManager.uploadSpeedBytesPerSec))/s", systemImage: "arrow.up.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Label("↓ \(byteRate(syncManager.downloadSpeedBytesPerSec))/s", systemImage: "arrow.down.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            showingAllPeers = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "laptopcomputer.and.iphone")
                                Text("\(syncManager.totalDeviceCount) 台设备在线")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                } header: { Text("状态") }
                Section("同步文件夹") {
                    ForEach(syncManager.folders) { folder in
                        FolderRow(folder: folder)
                    }
                    if syncManager.folders.isEmpty {
                        Text("尚未添加任何文件夹")
                            .foregroundStyle(.secondary)
                            .italic()
                    }
                }
            }
            .listStyle(.inset)
            .navigationTitle("FolderSync 仪表盘")
            .sheet(isPresented: $showingAllPeers) {
                AllPeersListView()
                    .environmentObject(syncManager)
            }
            .onAppear {
                // 设置窗口标识符，方便检查窗口是否已存在
                DispatchQueue.main.async {
                    if let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow || $0.isMainWindow }) {
                        window.identifier = NSUserInterfaceItemIdentifier("main")
                        window.title = "FolderSync 仪表盘"
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddFolder = true
                    } label: {
                        Label("添加文件夹", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingConflictCenter = true
                    } label: {
                        Label("冲突中心", systemImage: "exclamationmark.triangle")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSyncHistory = true
                    } label: {
                        Label("同步历史", systemImage: "clock.arrow.circlepath")
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
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytesPerSec))
    }
}

struct FolderRow: View {
    @EnvironmentObject var syncManager: SyncManager
    let folder: SyncFolder
    @State private var showingPeerList = false
    @State private var showingExcludeRules = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                    .font(.title2)
                
                VStack(alignment: .leading) {
                    Text(folder.localPath.lastPathComponent)
                        .font(.headline)
                    HStack(spacing: 4) {
                        Text("ID: \(folder.syncID)")
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 4)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(4)
                            .onTapGesture {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(folder.syncID, forType: .string)
                            }
                        
                        Text(folder.localPath.path)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    StatusBadge(status: folder.status)
                    
                    HStack(spacing: 4) {
                        Text("\(folder.fileCount ?? 0) 个文件")
                        if let folderCount = folder.folderCount, folderCount > 0 {
                            Text("•")
                            Text("\(folderCount) 个文件夹")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    
                    if folder.peerCount > 0 {
                        Button {
                            showingPeerList = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "laptopcomputer.and.iphone")
                                Text("\(folder.peerCount) 台设备在线")
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
            
            if folder.status == .syncing {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: folder.syncProgress)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                    
                    if let message = folder.lastSyncMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }
                .padding(.leading, 32)
                .padding(.top, 4)
            } else if let message = folder.lastSyncMessage, folder.status == .error {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.leading, 32)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                NSWorkspace.shared.open(folder.localPath)
            } label: {
                Label("在 Finder 中打开", systemImage: "folder")
            }
            
            Divider()
            
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(folder.syncID, forType: .string)
            } label: {
                Label("复制同步 ID", systemImage: "doc.on.doc")
            }
            
            Button {
                showingExcludeRules = true
            } label: {
                Label("排除规则", systemImage: "line.3.horizontal.decrease.circle")
            }
            
            Divider()
            
            Button(role: .destructive) {
                syncManager.removeFolder(folder)
            } label: {
                Label("移除文件夹", systemImage: "trash")
            }
        }
        .sheet(isPresented: $showingExcludeRules) {
            ExcludeRulesView(folder: folder)
                .environmentObject(syncManager)
        }
    }
}

struct StatusBadge: View {
    let status: SyncStatus
    
    var body: some View {
        Text(status.rawValue.uppercased())
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
    
    var body: some View {
        VStack(spacing: 20) {
            Text("添加同步文件夹")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 10) {
                Text("1. 本地文件夹地址")
                    .font(.subheadline).bold()
                
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK {
                        selectedPath = panel.url
                    }
                } label: {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                        Text(selectedPath?.path ?? "选择本地文件夹...")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            
            VStack(alignment: .leading, spacing: 10) {
                Text("2. 同步 ID")
                    .font(.subheadline).bold()
                
                HStack {
                    TextField("输入同步 ID 或点击右侧生成", text: $syncID)
                        .textFieldStyle(.roundedBorder)
                    
                    Button {
                        syncID = generateRandomSyncID()
                    } label: {
                        Image(systemName: "dice")
                            .padding(4)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }
                }
                
                Text("提示：如果该 ID 已存在于网络上，将自动加入现有同步组；否则将创建新的同步组。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                if !syncManager.peers.isEmpty {
                    Text("已发现 \(syncManager.peers.count) 台设备")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("等待发现其他设备...")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("添加同步") {
                    if let path = selectedPath, !syncID.isEmpty {
                        // 直接添加文件夹，系统会自动判断是加入现有同步组还是创建新同步组
                        // 如果网络上已有该 syncID，会自动加入；否则创建新同步组
                        let newFolder = SyncFolder(syncID: syncID, localPath: path, mode: .twoWay)
                        syncManager.addFolder(newFolder)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedPath == nil || syncID.isEmpty)
            }
        }
        .padding()
        .frame(width: 450)
    }
    
    private func generateRandomSyncID() -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<8).map { _ in letters.randomElement()! })
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
                                Text(device.isLocal ? "本机" : "远程设备")
                                    .font(.headline)
                                if device.isLocal {
                                    Text("(我)")
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
                                    .fill(.green)
                                    .frame(width: 6, height: 6)
                                Text(device.status)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if !device.isLocal {
                                    Text("•")
                                        .foregroundStyle(.secondary)
                                    Label("直连", systemImage: "network")
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
            .navigationTitle("所有设备")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 500, height: 400)
    }
}

struct PeerListView: View {
    @EnvironmentObject var syncManager: SyncManager
    let syncID: String
    
    var peers: [String] {
        Array(syncManager.folderPeers[syncID] ?? [])
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("在线同步设备")
                .font(.headline)
                .padding(.bottom, 4)
            
            if peers.isEmpty {
                Text("暂无在线设备")
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
                                        Label("直连", systemImage: "network")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text("•")
                                            .foregroundStyle(.secondary)
                                        Text("在线")
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

