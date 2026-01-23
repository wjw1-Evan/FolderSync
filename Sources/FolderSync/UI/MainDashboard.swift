import SwiftUI

struct MainDashboard: View {
    @EnvironmentObject var syncManager: SyncManager
    @State private var showingAddFolder = false
    
    var body: some View {
        NavigationStack {
            List {
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddFolder = true
                    } label: {
                        Label("添加文件夹", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddFolder) {
                AddFolderView()
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

struct FolderRow: View {
    @EnvironmentObject var syncManager: SyncManager
    let folder: SyncFolder
    @State private var showingPeerList = false
    
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
                    
                    if let lastSynced = folder.lastSyncedAt {
                        Text("上次同步: \(lastSynced.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
            
            Divider()
            
            Button(role: .destructive) {
                syncManager.removeFolder(folder)
            } label: {
                Label("移除文件夹", systemImage: "trash")
            }
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
    
    @State private var syncMode: Selection = .create
    @State private var errorMessage: String?
    @State private var isChecking = false
    
    enum Selection {
        case create, join
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("同步新文件夹")
                .font(.headline)
            
            Picker("同步方式", selection: $syncMode) {
                Text("创建新同步组").tag(Selection.create)
                Text("加入现有同步组").tag(Selection.join)
            }
            .pickerStyle(.segmented)
            
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
                    TextField(syncMode == .create ? "输入自定义 ID 或点击右侧生成" : "输入或粘贴同步 ID", text: $syncID)
                        .textFieldStyle(.roundedBorder)
                    
                    if syncMode == .create {
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
                }
            }
            
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            
            if syncMode == .join {
                Text("提示：加入现有同步组需要两边填写相同的 ID。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button(syncMode == .create ? "创建同步" : "加入同步") {
                    if let path = selectedPath, !syncID.isEmpty {
                        if syncMode == .join {
                            isChecking = true
                            Task {
                                let exists = await syncManager.checkIfSyncIDExists(syncID)
                                await MainActor.run {
                                    isChecking = false
                                    if exists {
                                        let newFolder = SyncFolder(syncID: syncID, localPath: path)
                                        syncManager.addFolder(newFolder)
                                        dismiss()
                                    } else {
                                        errorMessage = "同步 ID 不存在，请检查输入是否正确。"
                                    }
                                }
                            }
                        } else {
                            // Create mode: allow any ID or generated ID
                            let newFolder = SyncFolder(syncID: syncID, localPath: path)
                            syncManager.addFolder(newFolder)
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedPath == nil || syncID.isEmpty || isChecking)
                
                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                }
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
                                Image(systemName: "cpu")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading) {
                                    Text("Peer ID")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(peerID)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
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
        .frame(width: 300, height: 250)
    }
}

