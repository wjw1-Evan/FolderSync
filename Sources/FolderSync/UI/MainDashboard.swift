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
                try? StorageManager.shared.deleteFolder(folder.id)
                syncManager.folders.removeAll { $0.id == folder.id }
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

