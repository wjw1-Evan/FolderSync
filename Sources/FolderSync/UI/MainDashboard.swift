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
    
    var body: some View {
        VStack(spacing: 20) {
            Text("同步新文件夹")
                .font(.headline)
            
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
                    Text(selectedPath?.path ?? "选择文件夹...")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            }
            
            HStack {
                TextField("全局同步 ID (一致则同步)", text: $syncID)
                    .textFieldStyle(.roundedBorder)
                
                Button {
                    syncID = generateRandomSyncID()
                } label: {
                    Image(systemName: "dice")
                        .help("生成随机 ID")
                }
            }
            .onAppear {
                if syncID.isEmpty {
                    syncID = generateRandomSyncID()
                }
            }
            
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("开始同步") {
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
        .frame(width: 400)
    }
    
    private func generateRandomSyncID() -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<8).map { _ in letters.randomElement()! })
    }
}
