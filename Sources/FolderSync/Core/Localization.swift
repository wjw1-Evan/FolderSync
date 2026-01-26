import Foundation
import SwiftUI

/// 本地化字符串辅助扩展
extension String {
    /// 获取本地化字符串
    var localized: String {
        String(localized: String.LocalizationValue(stringLiteral: self), bundle: .module)
    }

    /// 获取带参数的本地化字符串
    func localized(_ arguments: CVarArg...) -> String {
        String(format: self.localized, arguments: arguments)
    }
}

/// 本地化辅助函数
enum LocalizedString {
    // MARK: - 通用
    static let upload = "上传".localized
    static let download = "下载".localized
    static let status = "状态".localized
    static let close = "关闭".localized
    static let cancel = "取消".localized
    static let done = "完成".localized
    static let add = "添加".localized
    static let refresh = "刷新".localized
    static let help = "帮助".localized
    static let quit = "退出".localized

    // MARK: - 仪表盘
    static let dashboard = "FolderSync 仪表盘".localized
    static let syncFolders = "同步文件夹".localized
    static let noFoldersAdded = "尚未添加任何文件夹".localized
    static let tapToAddFolder = "点击右上角的 + 按钮添加同步文件夹".localized
    static let addFolder = "添加文件夹".localized
    static let conflictCenter = "冲突中心".localized
    static let syncHistory = "同步历史".localized

    // MARK: - 设备
    static let online = "在线".localized
    static let offline = "离线".localized
    static let direct = "直连".localized
    static let local = "本机".localized
    static let remoteDevice = "远程设备".localized
    static let devicesList = "设备列表".localized
    static let me = "(我)".localized
    static let allDevices = "所有设备".localized
    static let onlineDevices = "在线同步设备".localized
    static let noOnlineDevices = "暂无在线设备".localized
    static let waitingForDevices = "等待发现其他设备...".localized

    // MARK: - 文件夹
    static let files = "个文件".localized
    static let folders = "个文件夹".localized
    static let devices = "台设备".localized
    static let onlineSuffix = "台在线".localized
    static let openInFinder = "在 Finder 中打开".localized
    static let copySyncID = "复制同步 ID".localized
    static let viewLogs = "查看日志".localized
    static let viewLocalChanges = "查看本地变更".localized
    static let localChangeHistory = "本地变更历史".localized
    static let searchLocalChanges = "搜索文件路径...".localized
    static let noLocalChanges = "暂无本地变更记录".localized
    static let changeCreated = "新建".localized
    static let changeModified = "修改".localized
    static let changeDeleted = "删除".localized
    static let changeRenamed = "重命名".localized
    static let showCurrentChangesOnly = "仅显示当前未同步变更".localized
    static let excludeRules = "排除规则".localized
    static let removeFolder = "移除文件夹".localized

    // MARK: - 添加文件夹
    static let addSyncFolder = "添加同步文件夹".localized
    static let localFolderPath = "1. 本地文件夹地址".localized
    static let dragFolderHere = "拖拽文件夹到此处，或点击选择".localized
    static let selectValidFolder = "请选择一个有效的文件夹".localized
    static let folderAlreadyAdded = "该文件夹已经添加到同步列表".localized
    static let cannotAddSubdirectory = "不能添加其他同步文件夹的子目录".localized
    static let syncID = "2. 同步 ID".localized
    static let enterSyncID = "输入同步 ID 或点击右侧生成".localized
    static let generateSyncID = "生成随机同步 ID".localized
    static let syncIDDescription = "如果该 ID 已存在于网络上，将自动加入现有同步组；否则将创建新的同步组。".localized
    static let syncIDMinLength = "同步 ID 至少需要 8 个字符".localized
    static let addSync = "添加同步".localized
    static let idLabel = "ID:".localized
    static let copied = "已复制".localized

    // MARK: - 冲突中心
    static let noConflicts = "暂无冲突".localized
    static let allFilesSynced = "所有文件已同步完成".localized
    static let unresolvedConflicts = "未解决的冲突".localized
    static let selectConflictToView = "选择冲突以查看详情".localized
    static let keepAllLocal = "全部保留本机版本".localized
    static let keepAllRemote = "全部保留远程版本".localized
    static let batchActions = "批量操作".localized
    static let keepLocal = "保留本机".localized
    static let keepRemote = "保留远程".localized
    static let filePath = "文件路径".localized
    static let syncIDLabel = "同步ID".localized
    static let showInFinder = "在 Finder 中显示".localized
    static let viewConflictFile = "查看冲突文件".localized

    // MARK: - 同步历史
    static let searchSyncHistory = "搜索同步历史...".localized
    static let allFolders = "所有文件夹".localized
    static let showErrorsOnly = "仅显示错误".localized
    static let noSyncRecords = "暂无同步记录".localized
    static let noMatchingRecords = "没有匹配的记录".localized
    static let records = "条记录".localized
    static let collapse = "收起".localized
    static let expand = "展开".localized
    static let filesLabel = "文件: ".localized
    static let andMoreFiles = "等 %d 个文件".localized
    static let countSuffix = "个".localized

    // MARK: - 排除规则
    static let excludeRulesTitle = "排除规则".localized
    static let gitignoreStyleRules = "使用 .gitignore 风格的匹配规则".localized
    static let examplePattern = "例如: *.log 或 build/".localized
    static let templates = "模板".localized
    static let ruleCannotBeEmpty = "规则不能为空".localized
    static let ruleAlreadyExists = "该规则已存在".localized
    static let ruleCannotContainLineBreaks = "规则不能包含换行符".localized
    static let addedRules = "已添加的规则".localized
    static let noExcludeRules = "暂无排除规则".localized
    static let allFilesWillBeSynced = "所有文件都会被同步".localized
    static let deleteRule = "删除规则".localized
    static let 条 = "条".localized

    // MARK: - 菜单
    static let showMainWindow = "显示主界面".localized
    static let launchAtLogin = "开机自动启动".localized

    // MARK: - 模板分类
    static let logFiles = "日志文件".localized
    static let temporaryFiles = "临时文件".localized
    static let buildDirectories = "构建目录".localized
    static let dependencyDirectories = "依赖目录".localized
    static let ideConfiguration = "IDE配置".localized
    static let versionControl = "版本控制".localized
    static let cacheDirectories = "缓存目录".localized

    // MARK: - 确认对话框
    static let confirmRemoveFolder = "确认移除文件夹".localized
    static let confirmRemoveFolderMessage = "确定要移除同步文件夹 \"%@\" 吗？此操作将停止该文件夹的同步，但不会删除本地文件。".localized
    static let remove = "移除".localized
    static let counting = "统计中...".localized
    static let pendingTransfers = "待传输".localized

    // MARK: - 状态
    static func syncStatus(_ status: SyncStatus) -> String {
        switch status {
        case .synced:
            return "已同步".localized
        case .syncing:
            return "同步中".localized
        case .error:
            return "错误".localized
        case .paused:
            return "已暂停".localized
        }
    }

    // MARK: - 格式化函数
    static func devicesDiscovered(_ count: Int) -> String {
        String(format: "已发现 %d 台设备".localized, count)
    }

    static func copySyncIDHelp(_ syncID: String) -> String {
        String(format: "复制同步ID: %@".localized, syncID)
    }

    static func fromPeer(_ peerID: String) -> String {
        String(format: "来自 %@".localized, peerID)
    }

    static func moreFiles(_ count: Int) -> String {
        String(format: andMoreFiles, count)
    }
}
