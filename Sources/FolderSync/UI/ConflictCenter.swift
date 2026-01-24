import SwiftUI

struct ConflictCenter: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var syncManager: SyncManager
    @State private var conflicts: [ConflictFile] = []
    
    var body: some View {
        NavigationStack {
            List {
                Section("未解决的冲突") {
                    if conflicts.isEmpty {
                        Text("暂无冲突")
                            .foregroundStyle(.secondary)
                            .italic()
                    } else {
                        ForEach(conflicts) { c in
                            ConflictRow(conflict: c, onKeepOriginal: { keepLocalAndResolve(c) }, onKeepConflict: { keepRemoteAndResolve(c) })
                        }
                    }
                }
            }
            .listStyle(.inset)
            .navigationTitle("冲突中心")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { refresh() }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
    
    private func folderBase(for syncID: String) -> URL? {
        syncManager.folders.first { $0.syncID == syncID }?.localPath
    }
    
    private func refresh() {
        conflicts = (try? StorageManager.shared.getAllConflicts(unresolvedOnly: true)) ?? []
    }
    
    private func keepLocalAndResolve(_ c: ConflictFile) {
        guard let base = folderBase(for: c.syncID) else { return }
        let conflictURL = base.appendingPathComponent(c.conflictPath)
        try? FileManager.default.removeItem(at: conflictURL)
        try? StorageManager.shared.resolveConflict(id: c.id)
        refresh()
    }
    
    private func keepRemoteAndResolve(_ c: ConflictFile) {
        guard let base = folderBase(for: c.syncID) else { return }
        let origURL = base.appendingPathComponent(c.relativePath)
        let conflictURL = base.appendingPathComponent(c.conflictPath)
        guard let data = try? Data(contentsOf: conflictURL) else { return }
        try? FileManager.default.createDirectory(at: origURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: origURL)
        try? FileManager.default.removeItem(at: conflictURL)
        try? StorageManager.shared.resolveConflict(id: c.id)
        refresh()
    }
}

private struct ConflictRow: View {
    let conflict: ConflictFile
    let onKeepOriginal: () -> Void
    let onKeepConflict: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(conflict.relativePath)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("来自 \(conflict.remotePeerID.prefix(12))…")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("保留本机版本", action: onKeepOriginal)
                    .buttonStyle(.bordered)
                Button("保留远程版本", action: onKeepConflict)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}
