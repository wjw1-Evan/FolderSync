using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace FolderSync.Data.Entities;

/// <summary>
/// Sync operation types
/// </summary>
public enum SyncOperation
{
    Add = 0,
    Update = 1,
    Delete = 2
}

/// <summary>
/// Sync status types
/// </summary>
public enum SyncStatus
{
    Success = 0,
    Failed = 1,
    Pending = 2
}

/// <summary>
/// Represents a sync history record
/// </summary>
public class SyncHistory
{
    [Key]
    [DatabaseGenerated(DatabaseGeneratedOption.Identity)]
    public int Id { get; set; }

    /// <summary>
    /// Type of operation (Add/Update/Delete)
    /// </summary>
    public SyncOperation Operation { get; set; }

    /// <summary>
    /// File path that was synced
    /// </summary>
    [Required]
    [MaxLength(2000)]
    public string FilePath { get; set; } = string.Empty;

    /// <summary>
    /// Sync status
    /// </summary>
    public SyncStatus Status { get; set; } = SyncStatus.Pending;

    /// <summary>
    /// Error message if failed
    /// </summary>
    [MaxLength(1000)]
    public string? ErrorMessage { get; set; }

    /// <summary>
    /// When this sync operation occurred
    /// </summary>
    public DateTime Timestamp { get; set; } = DateTime.UtcNow;

    /// <summary>
    /// Source device ID that initiated the sync
    /// </summary>
    [MaxLength(256)]
    public string? SourceDeviceId { get; set; }

    /// <summary>
    /// File size in bytes
    /// </summary>
    public long? FileSize { get; set; }
}
