using FolderSync.Data.Entities;

namespace FolderSync.Sync.Models;

public enum SyncTaskType
{
    Upload,
    Download,
    Delete
}

public class SyncTask
{
    public Guid Id { get; } = Guid.NewGuid();
    public string FilePath { get; set; } = string.Empty;
    public string TargetIp { get; set; } = string.Empty;
    public SyncTaskType Type { get; set; }
    public SyncPriority Priority { get; set; } = SyncPriority.Medium;
    public DateTime CreatedAt { get; } = DateTime.UtcNow;
    public int RetryCount { get; set; } = 0;
    public string? Hash { get; set; }
    public bool IsQuickSend { get; set; }
}
