import Foundation

public class SingleInstanceLock {
    private let lockFileURL: URL
    private var fileDescriptor: Int32 = -1

    public init(name: String = "FolderSync") {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let folderSyncDir = appSupport.appendingPathComponent("FolderSync", isDirectory: true)

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            at: folderSyncDir, withIntermediateDirectories: true)

        self.lockFileURL = folderSyncDir.appendingPathComponent("\(name).lock")
    }

    /// Try to acquire the lock. Returns true if successful, false if already locked.
    public func tryLock() -> Bool {
        let path = lockFileURL.path

        // Open the file (create if it doesn't exist)
        fileDescriptor = open(path, O_CREAT | O_RDWR, 0o666)
        if fileDescriptor == -1 {
            return false
        }

        // Try to acquire an exclusive lock without blocking
        let result = flock(fileDescriptor, LOCK_EX | LOCK_NB)
        if result == 0 {
            // Lock acquired successfully
            // Write current process ID to the file for debugging purposes
            let pid = String(ProcessInfo.processInfo.processIdentifier)
            if let data = pid.data(using: .utf8) {
                ftruncate(fileDescriptor, 0)
                write(fileDescriptor, (data as NSData).bytes, data.count)
            }
            return true
        } else {
            // Lock failed (likely already held by another instance)
            close(fileDescriptor)
            fileDescriptor = -1
            return false
        }
    }

    deinit {
        if fileDescriptor != -1 {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }
    }
}
