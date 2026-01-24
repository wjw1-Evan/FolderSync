import SwiftUI

struct ExcludeRulesView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var syncManager: SyncManager
    let folder: SyncFolder
    @State private var patterns: [String]
    @State private var newPattern: String = ""
    
    init(folder: SyncFolder) {
        self.folder = folder
        _patterns = State(initialValue: folder.excludePatterns)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("排除规则")
                .font(.headline)
            Text(" .gitignore 风格，例如: *.log, build/, node_modules/")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("例如 *.log 或 build/", text: $newPattern)
                    .textFieldStyle(.roundedBorder)
                Button("添加") {
                    let t = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty, !patterns.contains(t) else { return }
                    patterns.append(t)
                    newPattern = ""
                    persist()
                }
                .disabled(newPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            List {
                ForEach(patterns, id: \.self) { p in
                    HStack {
                        Text(p)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            patterns.removeAll { $0 == p }
                            persist()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.inset)
            Spacer()
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 400, height: 320)
    }
    
    private func persist() {
        var f = folder
        f.excludePatterns = patterns
        syncManager.updateFolder(f)
    }
}
