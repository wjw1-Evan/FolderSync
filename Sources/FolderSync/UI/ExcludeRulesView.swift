import SwiftUI

struct ExcludeRulesView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var syncManager: SyncManager
    let folder: SyncFolder
    @State private var patterns: [String]
    @State private var newPattern: String = ""
    @State private var errorMessage: String?
    @State private var showingTemplates = false
    
    // 常用排除规则模板
    private var commonTemplates: [(String, [String])] {
        [
            (LocalizedString.logFiles, ["*.log", "*.log.*"]),
            (LocalizedString.temporaryFiles, ["*.tmp", "*.temp", ".DS_Store"]),
            (LocalizedString.buildDirectories, ["build/", "dist/", "target/", ".build/"]),
            (LocalizedString.dependencyDirectories, ["node_modules/", "vendor/", ".venv/", "venv/"]),
            (LocalizedString.ideConfiguration, [".idea/", ".vscode/", "*.swp", "*.swo"]),
            (LocalizedString.versionControl, [".git/", ".svn/", ".hg/"]),
            (LocalizedString.cacheDirectories, [".cache/", "*.cache", ".gradle/"]),
        ]
    }
    
    init(folder: SyncFolder) {
        self.folder = folder
        _patterns = State(initialValue: folder.excludePatterns)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题和说明
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedString.excludeRulesTitle)
                    .font(.title2)
                    .fontWeight(.bold)
                Text(LocalizedString.gitignoreStyleRules)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 16)
            
            // 添加规则区域
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField(LocalizedString.examplePattern, text: $newPattern)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            addPattern()
                        }
                    
                    Button {
                        addPattern()
                    } label: {
                        Label(LocalizedString.add, systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    
                    Menu {
                        ForEach(commonTemplates, id: \.0) { category, templates in
                            Menu(category) {
                                ForEach(templates, id: \.self) { template in
                                    Button(template) {
                                        newPattern = template
                                    }
                                }
                            }
                        }
                    } label: {
                        Label(LocalizedString.templates, systemImage: "list.bullet")
                    }
                }
                
                if let error = errorMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .padding(6)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(4)
                }
            }
            .padding(.bottom, 16)
            
            // 规则列表 - 使用灵活高度
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(LocalizedString.addedRules)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    if !patterns.isEmpty {
                        Text("\(patterns.count)\(LocalizedString.条)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                if patterns.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary.opacity(0.3))
                        Text(LocalizedString.noExcludeRules)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(LocalizedString.allFilesWillBeSynced)
                            .font(.caption)
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 20)
                } else {
                    List {
                        ForEach(patterns, id: \.self) { pattern in
                            HStack(spacing: 8) {
                                Image(systemName: "line.3.horizontal.decrease")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                                    .frame(minWidth: 16)
                                Text(pattern)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                Spacer()
                                Button(role: .destructive) {
                                    withAnimation {
                                        patterns.removeAll { $0 == pattern }
                                        persist()
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .help(LocalizedString.deleteRule)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(minHeight: 150, maxHeight: 300)
            
            Spacer(minLength: 16)
            
            Divider()
                .padding(.vertical, 8)
            
            // 底部按钮
            HStack {
                Button(LocalizedString.help) {
                    NSWorkspace.shared.open(URL(string: "https://git-scm.com/docs/gitignore#_pattern_format")!)
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button(LocalizedString.done) { 
                    dismiss() 
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .frame(minHeight: 400, maxHeight: 600)
        .onAppear {
            // 从 syncManager 获取最新的文件夹数据，确保显示最新的排除规则
            if let updatedFolder = syncManager.folders.first(where: { $0.id == folder.id }) {
                patterns = updatedFolder.excludePatterns
            }
        }
    }
    
    private func addPattern() {
        let trimmed = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmed.isEmpty else {
            errorMessage = LocalizedString.ruleCannotBeEmpty
            return
        }
        
        guard !patterns.contains(trimmed) else {
            errorMessage = LocalizedString.ruleAlreadyExists
            return
        }
        
        // 基本验证：检查是否包含非法字符
        if trimmed.contains("\n") || trimmed.contains("\r") {
            errorMessage = LocalizedString.ruleCannotContainLineBreaks
            return
        }
        
        withAnimation {
            patterns.append(trimmed)
            newPattern = ""
            errorMessage = nil
            persist()
        }
    }
    
    private func persist() {
        var f = folder
        f.excludePatterns = patterns
        syncManager.updateFolder(f)
    }
}
