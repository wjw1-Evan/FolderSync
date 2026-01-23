import SwiftUI

struct MainDashboard: View {
    @EnvironmentObject var syncManager: SyncManager
    @State private var showingAddFolder = false
    @State private var showingAddPeer = false
    
    var body: some View {
        NavigationStack {
            List {
                Section("本机 ID (PeerID)") {
                    HStack {
                        Text(syncManager.p2pNode.peerID ?? "获取中...")
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        Spacer()
                        
                        Button {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(syncManager.p2pNode.peerID ?? "", forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("复制本机 ID")
                    }
                }
                
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
                
                Section("对等设备 (Peers)") {
                    ForEach(syncManager.peers, id: \.self) { peer in
                        HStack {
                            Image(systemName: "desktopcomputer")
                            Text(peer)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                    
                    Button {
                        showingAddPeer = true
                    } label: {
                        Label("添加同步对等端...", systemImage: "person.badge.plus")
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
            .sheet(isPresented: $showingAddPeer) {
                AddPeerView()
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

struct FolderRow: View {
    let folder: SyncFolder
    
    var body: some View {
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
                        .help("点击复制同步 ID")
                        .onTapGesture {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(folder.syncID, forType: .string)
                        }
                        .contextMenu {
                            Button {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(folder.syncID, forType: .string)
                            } label: {
                                Label("复制同步 ID", systemImage: "doc.on.doc")
                            }
                        }
                    
                    Text(folder.localPath.path)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            StatusBadge(status: folder.status)
        }
        .padding(.vertical, 4)
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
                Text("2. 同步 ID (\(syncMode == .create ? "自动生成" : "手动输入"))")
                    .font(.subheadline).bold()
                
                HStack {
                    TextField(syncMode == .create ? "点击右侧生成 ID" : "粘贴来自对方的同步 ID", text: $syncID)
                        .textFieldStyle(.roundedBorder)
                        .disabled(syncMode == .create)
                    
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
                        let newFolder = SyncFolder(syncID: syncID, localPath: path)
                        try? StorageManager.shared.saveFolder(newFolder)
                        syncManager.folders.append(newFolder)
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

struct AddPeerView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var syncManager: SyncManager
    @State private var peerID: String = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("添加同步对等端")
                .font(.headline)
            
            TextField("输入对方的 PeerID", text: $peerID)
                .textFieldStyle(.roundedBorder)
            
            Text("PeerID 是对方设备在『本机 ID』处显示的字符串")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("添加设备") {
                    if !peerID.isEmpty {
                        syncManager.peers.append(peerID)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(peerID.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
