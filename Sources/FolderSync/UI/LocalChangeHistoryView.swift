import SwiftUI

/// 本地变更查看视图
/// 显示文件夹的本地变更历史记录
struct LocalChangeHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var syncManager: SyncManager
    
    let folder: SyncFolder
    
    @State private var changes: [LocalChange] = []
    @State private var filteredChanges: [LocalChange] = []
    @State private var isLoading: Bool = false
    @State private var searchText: String = ""
    @State private var selectedChangeType: ChangeTypeFilter = .all
    @State private var refreshTimer: Timer?
    
    enum ChangeTypeFilter {
        case all
        case created
        case modified
        case deleted
        case renamed
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部工具栏
                toolbarView
                
                Divider()
                
                // 内容区域
                if isLoading && changes.isEmpty {
                    loadingView
                } else {
                    contentView
                }
            }
            .navigationTitle(LocalizedString.localChangeHistory)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedString.close) { dismiss() }
                }
            }
            .onAppear {
                refresh()
                // 启动定时器，每秒自动刷新
                startAutoRefresh()
            }
            .onDisappear {
                // 停止定时器
                stopAutoRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .localChangeAdded)) { _ in
                refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .localChangeHistoryRefresh)) { notification in
                // 检查是否是当前文件夹的刷新通知
                if let folderID = notification.userInfo?["folderID"] as? UUID,
                   folderID == folder.id {
                    refresh()
                }
            }
            .onChange(of: searchText) { _, _ in applyFilters() }
            .onChange(of: selectedChangeType) { _, _ in applyFilters() }
        }
        .frame(minWidth: 600, minHeight: 500)
    }
    
    // MARK: - 工具栏
    private var toolbarView: some View {
        VStack(spacing: 12) {
            // 搜索和筛选
            HStack(spacing: 12) {
                // 搜索框
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索文件路径...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
                
                // 变更类型筛选
                Menu {
                    Button("全部") { selectedChangeType = .all }
                    Divider()
                    Button("新建") { selectedChangeType = .created }
                    Button("修改") { selectedChangeType = .modified }
                    Button("删除") { selectedChangeType = .deleted }
                    Button("重命名") { selectedChangeType = .renamed }
                } label: {
                    HStack {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                        Text(changeTypeLabel)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 12)
    }
    
    private var changeTypeLabel: String {
        switch selectedChangeType {
        case .all: return "全部类型"
        case .created: return "新建"
        case .modified: return "修改"
        case .deleted: return "删除"
        case .renamed: return "重命名"
        }
    }
    
    // MARK: - 加载视图
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("正在加载...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - 内容视图
    private var contentView: some View {
        Group {
            if filteredChanges.isEmpty {
                emptyStateView
            } else {
                changesListView(changes: filteredChanges)
            }
        }
    }
    
    // MARK: - 空状态视图
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "clock.badge.xmark")
                .font(.system(size: 64))
                .foregroundStyle(.secondary.opacity(0.3))
            
            Text("暂无历史变更记录")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            Text("文件变更记录将显示在这里")
                .font(.subheadline)
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - 变更列表视图
    private func changesListView(changes: [LocalChange]) -> some View {
        List {
            Section {
                ForEach(changes) { change in
                    ChangeRow(change: change)
                }
            } header: {
                HStack {
                    Text("历史变更记录")
                    Spacer()
                    Text("\(changes.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
    }
    
    // MARK: - 数据加载
    private func refresh() {
        isLoading = true
        Task {
            await loadHistoryChanges()
            await MainActor.run {
                isLoading = false
                applyFilters()
            }
        }
    }
    
    
    private func loadHistoryChanges() async {
        do {
            let loadedChanges = try StorageManager.shared.getLocalChanges(
                folderID: folder.id,
                limit: 500,
                forceReload: true
            )
            await MainActor.run {
                changes = loadedChanges
            }
        } catch {
            AppLogger.syncPrint("[LocalChangeHistoryView] ⚠️ 加载历史变更失败: \(error)")
            await MainActor.run {
                changes = []
            }
        }
    }
    
    // MARK: - 筛选
    private func applyFilters() {
        var result = changes
        
        // 按类型筛选
        if selectedChangeType != .all {
            let targetType: LocalChange.ChangeType = {
                switch selectedChangeType {
                case .created: return .created
                case .modified: return .modified
                case .deleted: return .deleted
                case .renamed: return .renamed
                case .all: return .created // 不会执行到这里
                }
            }()
            result = result.filter { $0.changeType == targetType }
        }
        
        // 按搜索文本筛选
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { $0.path.lowercased().contains(query) }
        }
        
        filteredChanges = result
    }
    
    // MARK: - 自动刷新
    private func startAutoRefresh() {
        // 停止现有的定时器
        stopAutoRefresh()
        
        // 创建新的定时器，每秒刷新一次
        // 注意：由于 View 是 struct（值类型），不会有循环引用问题
        // 我们在 onDisappear 中会停止定时器，确保资源正确释放
        let folderID = folder.id
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                // 使用 NotificationCenter 触发刷新，避免直接捕获 View
                NotificationCenter.default.post(
                    name: .localChangeHistoryRefresh,
                    object: nil,
                    userInfo: ["folderID": folderID]
                )
            }
        }
    }
    
    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

// MARK: - 变更行视图
private struct ChangeRow: View {
    let change: LocalChange
    
    var body: some View {
        HStack(spacing: 12) {
            // 图标
            Image(systemName: iconName)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 32)
            
            // 文件信息
            VStack(alignment: .leading, spacing: 6) {
                // 文件路径
                Text(change.path)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                // 变更类型和大小
                HStack(spacing: 8) {
                    // 变更类型标签
                    Text(typeLabel)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.15))
                        .cornerRadius(4)
                    
                    // 文件大小
                    if let size = change.size, size > 0 {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(formatSize(size))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // 时间
            VStack(alignment: .trailing, spacing: 4) {
                Text(formatDate(change.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(change.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.7))
            }
        }
        .padding(.vertical, 8)
    }
    
    private var iconName: String {
        switch change.changeType {
        case .created: return "plus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .deleted: return "trash.circle.fill"
        case .renamed: return "arrow.triangle.2.circlepath.circle.fill"
        }
    }
    
    private var color: Color {
        switch change.changeType {
        case .created: return .green
        case .modified: return .blue
        case .deleted: return .red
        case .renamed: return .orange
        }
    }
    
    private var typeLabel: String {
        switch change.changeType {
        case .created: return LocalizedString.changeCreated
        case .modified: return LocalizedString.changeModified
        case .deleted: return LocalizedString.changeDeleted
        case .renamed: return LocalizedString.changeRenamed
        }
    }
    
    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
