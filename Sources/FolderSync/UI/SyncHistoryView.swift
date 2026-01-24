import SwiftUI

struct SyncHistoryView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var syncManager: SyncManager
    @State private var logs: [SyncLog] = []
    
    var body: some View {
        NavigationStack {
            List {
                Section("同步历史") {
                    if logs.isEmpty {
                        Text("暂无同步记录")
                            .foregroundStyle(.secondary)
                            .italic()
                    } else {
                        ForEach(logs) { log in
                            SyncLogRow(log: log, folderName: folderName(for: log.folderID))
                        }
                    }
                }
            }
            .listStyle(.inset)
            .navigationTitle("同步历史")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { refresh() }
        }
        .frame(minWidth: 500, minHeight: 360)
    }
    
    private func folderName(for folderID: UUID) -> String {
        syncManager.folders.first { $0.id == folderID }?.localPath.lastPathComponent ?? "—"
    }
    
    private func refresh() {
        logs = (try? StorageManager.shared.getSyncLogs(limit: 50)) ?? []
    }
}

private struct SyncLogRow: View {
    let log: SyncLog
    let folderName: String
    
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
                Text("\(log.filesCount) 个文件")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if log.bytesTransferred > 0 {
                    Text("•")
                    Text(byteCount(log.bytesTransferred))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let err = log.errorMessage {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func byteCount(_ n: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: n)
    }
}
