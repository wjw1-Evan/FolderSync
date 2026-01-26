import Foundation
import os.log

/// 统一的日志系统，用于替代 print 语句
/// 日志会写入文件，不会在控制台显示
public struct AppLogger {
    private static let subsystem = "com.FolderSync.App"
    private static var loggers: [String: Logger] = [:]
    
    /// 获取指定类别的日志记录器
    public static func logger(for category: String) -> Logger {
        if let existing = loggers[category] {
            return existing
        }
        let newLogger = Logger(subsystem: subsystem, category: category)
        loggers[category] = newLogger
        return newLogger
    }
    
    /// 写入日志文件（用于调试）
    private static func writeToLogFile(_ message: String, level: String = "INFO") {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folderSyncDir = appSupport.appendingPathComponent("FolderSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderSyncDir, withIntermediateDirectories: true)
        
        let logFile = folderSyncDir.appendingPathComponent("app.log")
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        let logMessage = "[\(timestamp)] [\(level)] \(message)\n"
        
        if let data = logMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logFile) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }
    
    /// 记录信息日志
    public static func info(_ message: String, category: String = "General") {
        let logger = logger(for: category)
        logger.info("\(message)")
        writeToLogFile(message, level: "INFO")
    }
    
    /// 记录警告日志
    public static func warning(_ message: String, category: String = "General") {
        let logger = logger(for: category)
        logger.warning("\(message)")
        writeToLogFile(message, level: "WARNING")
    }
    
    /// 记录错误日志
    public static func error(_ message: String, category: String = "General") {
        let logger = logger(for: category)
        logger.error("\(message)")
        writeToLogFile(message, level: "ERROR")
    }
    
    /// 记录调试日志（仅在调试模式下）
    public static func debug(_ message: String, category: String = "General") {
        #if DEBUG
        let logger = logger(for: category)
        logger.debug("\(message)")
        writeToLogFile(message, level: "DEBUG")
        #endif
    }
}

extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}
