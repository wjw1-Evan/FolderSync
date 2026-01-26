import SwiftUI

struct SyncHistoryView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var syncManager: SyncManager
    @State private var logs: [SyncLog] = []
    @State private var filteredLogs: [SyncLog] = []
    @State private var searchText: String = ""
    @State private var selectedFolderID: UUID? = nil
    @State private var showErrorsOnly: Bool = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 搜索和筛选栏
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField(LocalizedString.searchSyncHistory, text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                    
                    HStack {
                        // 文件夹筛选
                        Menu {
                            Button(LocalizedString.allFolders) {
                                selectedFolderID = nil
                            }
                            Divider()
                            ForEach(syncManager.folders) { folder in
                                Button(folder.localPath.lastPathComponent) {
                                    selectedFolderID = folder.id
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                Text(selectedFolderID == nil ? LocalizedString.allFolders : folderName(for: selectedFolderID!))
                            }
                            .font(.caption)
                        }
                        
                        Spacer()
                        
                        // 仅显示错误
                        Toggle(LocalizedString.showErrorsOnly, isOn: $showErrorsOnly)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                
                Divider()
                
                // 日志列表
                List {
                    Section {
                        if filteredLogs.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "clock.badge.xmark")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.secondary.opacity(0.3))
                                Text(logs.isEmpty ? LocalizedString.noSyncRecords : LocalizedString.noMatchingRecords)
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        } else {
                            ForEach(filteredLogs) { log in
                                SyncLogRow(log: log, folderName: folderName(for: log.folderID))
                            }
                        }
                    } header: {
                        HStack {
                            Text(LocalizedString.syncHistory)
                            Spacer()
                            if !filteredLogs.isEmpty {
                                Text("\(filteredLogs.count)\(LocalizedString.records)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            .navigationTitle(LocalizedString.syncHistory)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedString.close) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        refresh()
                    } label: {
                        Label(LocalizedString.refresh, systemImage: "arrow.clockwise")
                    }
                }
            }
            .onAppear { refresh() }
            .onChange(of: searchText) { _, _ in applyFilters() }
            .onChange(of: selectedFolderID) { _, _ in applyFilters() }
            .onChange(of: showErrorsOnly) { _, _ in applyFilters() }
        }
        .frame(minWidth: 600, minHeight: 500)
    }
    
    private func folderName(for folderID: UUID) -> String {
        syncManager.folders.first { $0.id == folderID }?.localPath.lastPathComponent ?? "—"
    }
    
    private func refresh() {
        logs = (try? StorageManager.shared.getSyncLogs(limit: 100)) ?? []
        applyFilters()
    }
    
    private func applyFilters() {
        var result = logs
        
        // 文件夹筛选
        if let folderID = selectedFolderID {
            result = result.filter { $0.folderID == folderID }
        }
        
        // 错误筛选
        if showErrorsOnly {
            result = result.filter { $0.errorMessage != nil }
        }
        
        // 搜索筛选
        if !searchText.isEmpty {
            let searchLower = searchText.lowercased()
            result = result.filter { log in
                folderName(for: log.folderID).lowercased().contains(searchLower) ||
                (log.peerID?.lowercased().contains(searchLower) ?? false) ||
                (log.errorMessage?.lowercased().contains(searchLower) ?? false) ||
                (log.syncedFiles?.contains { $0.fileName.lowercased().contains(searchLower) } ?? false)
            }
        }
        
        filteredLogs = result
    }
}

private struct SyncLogRow: View {
    let log: SyncLog
    let folderName: String
    @State private var isExpanded = true // 默认展开显示文件列表
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: log.errorMessage != nil ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(log.errorMessage != nil ? .red : .green)
                Text(folderName)
                    .font(.subheadline)
                if let pid = log.peerID {
                    Text("→ \(String(pid.prefix(12)))…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(log.startedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("\(log.filesCount)\(LocalizedString.files)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if log.bytesTransferred > 0 {
                    Text("•")
                    Text(byteCount(log.bytesTransferred))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let files = log.syncedFiles, !files.isEmpty {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            Text(isExpanded ? LocalizedString.collapse : LocalizedString.expand)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let err = log.errorMessage {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            
            // 展开显示文件列表（默认展开）
            if isExpanded, let files = log.syncedFiles, !files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                        .padding(.vertical, 2)
                    ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                        HStack(spacing: 8) {
                            Image(systemName: iconForOperation(file.operation))
                                .foregroundStyle(colorForOperation(file.operation))
                                .font(.caption)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.fileName)
                                    .font(.caption)
                                    .lineLimit(1)
                                if let folderName = file.folderName {
                                    Text(folderName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else if !file.path.isEmpty && file.path != file.fileName {
                                    // 显示相对路径（如果与文件名不同）
                                    Text(file.path)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(byteCount(file.size))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 4)
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(4)
                    }
                }
                .padding(.leading, 20)
                .padding(.top, 4)
            } else if let files = log.syncedFiles, !files.isEmpty {
                // 未展开时显示前几个文件名
                HStack(spacing: 4) {
                    Text(LocalizedString.filesLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(Array(files.prefix(3).enumerated()), id: \.offset) { index, file in
                        Text(file.fileName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if index < min(2, files.count - 1) {
                            Text("、".localized)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if files.count > 3 {
                        Text(LocalizedString.moreFiles(files.count))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 20)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func byteCount(_ n: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: n)
    }
    
    private func iconForOperation(_ op: SyncLog.SyncedFileInfo.FileOperation) -> String {
        switch op {
        case .upload: return "arrow.up.circle.fill"
        case .download: return "arrow.down.circle.fill"
        case .delete: return "trash.circle.fill"
        case .conflict: return "exclamationmark.triangle.fill"
        }
    }
    
    private func colorForOperation(_ op: SyncLog.SyncedFileInfo.FileOperation) -> Color {
        switch op {
        case .upload: return .blue
        case .download: return .green
        case .delete: return .red
        case .conflict: return .orange
        }
    }
}
