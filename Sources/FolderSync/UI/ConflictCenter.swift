import SwiftUI

struct ConflictCenter: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var syncManager: SyncManager
    @State private var conflicts: [ConflictFile] = []
    @State private var selectedConflict: ConflictFile?
    @State private var isResolving = false
    
    var body: some View {
        NavigationStack {
            HSplitView {
                // 冲突列表
                List(selection: $selectedConflict) {
                    Section {
                        if conflicts.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.green.opacity(0.5))
                                Text(LocalizedString.noConflicts)
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                Text(LocalizedString.allFilesSynced)
                                    .font(.caption)
                                    .foregroundStyle(.secondary.opacity(0.8))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        } else {
                            ForEach(conflicts) { conflict in
                                ConflictRow(conflict: conflict, onKeepOriginal: { 
                                    Task { await resolveConflict(conflict, keepLocal: true) }
                                }, onKeepConflict: { 
                                    Task { await resolveConflict(conflict, keepLocal: false) }
                                })
                                .tag(conflict)
                            }
                        }
                    } header: {
                        HStack {
                            Text(LocalizedString.unresolvedConflicts)
                            Spacer()
                            if !conflicts.isEmpty {
                                Text("\(conflicts.count)\(LocalizedString.countSuffix)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 300)
                
                // 详情面板
                if let conflict = selectedConflict {
                    ConflictDetailView(conflict: conflict, folderBase: folderBase(for: conflict.syncID))
                        .frame(minWidth: 300)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary.opacity(0.3))
                        Text(LocalizedString.selectConflictToView)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minWidth: 300)
                }
            }
            .navigationTitle(LocalizedString.conflictCenter)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(LocalizedString.conflictCenter)
                            .font(.headline)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedString.close) { dismiss() }
                }
                if !conflicts.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button(LocalizedString.keepAllLocal) {
                                Task {
                                    for conflict in conflicts {
                                        await resolveConflict(conflict, keepLocal: true)
                                    }
                                }
                            }
                            Button(LocalizedString.keepAllRemote) {
                                Task {
                                    for conflict in conflicts {
                                        await resolveConflict(conflict, keepLocal: false)
                                    }
                                }
                            }
                        } label: {
                            Label(LocalizedString.batchActions, systemImage: "ellipsis.circle")
                        }
                    }
                }
            }
            .onAppear { 
                refresh()
                if !conflicts.isEmpty {
                    selectedConflict = conflicts.first
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
    
    private func folderBase(for syncID: String) -> URL? {
        syncManager.folders.first { $0.syncID == syncID }?.localPath
    }
    
    private func refresh() {
        conflicts = (try? StorageManager.shared.getAllConflicts(unresolvedOnly: true)) ?? []
        if selectedConflict != nil && !conflicts.contains(where: { $0.id == selectedConflict?.id }) {
            selectedConflict = conflicts.first
        }
    }
    
    private func resolveConflict(_ c: ConflictFile, keepLocal: Bool) async {
        guard !isResolving else { return }
        isResolving = true
        defer { isResolving = false }
        
        guard let base = folderBase(for: c.syncID) else { return }
        
        if keepLocal {
            // 保留本机版本：删除冲突文件
            let conflictURL = base.appendingPathComponent(c.conflictPath)
            try? FileManager.default.removeItem(at: conflictURL)
        } else {
            // 保留远程版本：用冲突文件替换原文件
            let origURL = base.appendingPathComponent(c.relativePath)
            let conflictURL = base.appendingPathComponent(c.conflictPath)
            guard let data = try? Data(contentsOf: conflictURL) else { return }
            try? FileManager.default.createDirectory(at: origURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: origURL)
            try? FileManager.default.removeItem(at: conflictURL)
        }
        
        try? StorageManager.shared.resolveConflict(id: c.id)
        await MainActor.run {
            refresh()
        }
    }
}

private struct ConflictRow: View {
    let conflict: ConflictFile
    let onKeepOriginal: () -> Void
    let onKeepConflict: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conflict.relativePath)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    Text(LocalizedString.fromPeer(String(conflict.remotePeerID.prefix(12)) + "…"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button {
                    onKeepOriginal()
                } label: {
                    Label(LocalizedString.keepLocal, systemImage: "laptopcomputer")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Button {
                    onKeepConflict()
                } label: {
                    Label(LocalizedString.keepRemote, systemImage: "arrow.down.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ConflictDetailView: View {
    let conflict: ConflictFile
    let folderBase: URL?
    
    @State private var localFileSize: Int64?
    @State private var remoteFileSize: Int64?
    @State private var localModified: Date?
    @State private var remoteModified: Date?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 文件信息
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "doc.fill")
                            .foregroundStyle(.blue)
                            .font(.title2)
                        Text(conflict.relativePath)
                            .font(.headline)
                            .lineLimit(2)
                    }
                    
                    Divider()
                    
                    // 文件路径
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedString.filePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(conflict.relativePath)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                    }
                    
                    // 同步ID
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedString.syncIDLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(conflict.syncID)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                    }
                    
                    // 远程设备
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedString.remoteDevice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(conflict.remotePeerID)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
                
                // 操作按钮
                VStack(spacing: 8) {
                    Button {
                        if let base = folderBase {
                            let url = base.appendingPathComponent(conflict.relativePath)
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    } label: {
                        Label(LocalizedString.showInFinder, systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    
                    Button {
                        if let base = folderBase {
                            let url = base.appendingPathComponent(conflict.conflictPath)
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    } label: {
                        Label(LocalizedString.viewConflictFile, systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .onAppear {
            loadFileInfo()
        }
    }
    
    private func loadFileInfo() {
        guard let base = folderBase else { return }
        
        // 加载本机文件信息
        let localURL = base.appendingPathComponent(conflict.relativePath)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path) {
            localFileSize = attrs[.size] as? Int64
            localModified = attrs[.modificationDate] as? Date
        }
        
        // 加载冲突文件信息
        let conflictURL = base.appendingPathComponent(conflict.conflictPath)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: conflictURL.path) {
            remoteFileSize = attrs[.size] as? Int64
            remoteModified = attrs[.modificationDate] as? Date
        }
    }
}
