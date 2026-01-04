using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace FolderSync.Data.Entities;

/// <summary>
/// Sync priority levels
/// </summary>
public enum SyncPriority
{
    Low = 0,
    Medium = 1,
    High = 2
}

/// <summary>
/// Represents a folder sync configuration
/// </summary>
public class SyncConfiguration
{
    [Key]
    [DatabaseGenerated(DatabaseGeneratedOption.Identity)]
    public int Id { get; set; }

    /// <summary>
    /// Local folder path to sync
    /// </summary>
    [Required]
    [MaxLength(1000)]
    public string LocalPath { get; set; } = string.Empty;

    /// <summary>
    /// Whether sync is enabled for this folder
    /// </summary>
    public bool SyncEnabled { get; set; } = true;

    /// <summary>
    /// Sync priority (High/Medium/Low)
    /// </summary>
    public SyncPriority Priority { get; set; } = SyncPriority.Medium;

    /// <summary>
    /// Filter rules in JSON format (file types, sizes, dates)
    /// </summary>
    [MaxLength(4000)]
    public string? FilterRules { get; set; }

    /// <summary>
    /// Allowed window start (0-23), -1 if 24/7
    /// </summary>
    public int ScheduleStartHour { get; set; } = -1;

    /// <summary>
    /// Allowed window end (0-23), -1 if 24/7
    /// </summary>
    public int ScheduleEndHour { get; set; } = -1;

    /// <summary>
    /// When this configuration was created
    /// </summary>
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;

    /// <summary>
    /// Last successful sync timestamp
    /// </summary>
    public DateTime? LastSyncAt { get; set; }

    /// <summary>
    /// Navigation property to file metadata
    /// </summary>
    public virtual ICollection<FileMetadata> Files { get; set; } = new List<FileMetadata>();

    public bool IsInScheduleWindow()
    {
        if (ScheduleStartHour == -1 || ScheduleEndHour == -1) return true;
        
        int currentHour = DateTime.Now.Hour;
        if (ScheduleStartHour <= ScheduleEndHour)
        {
            return currentHour >= ScheduleStartHour && currentHour <= ScheduleEndHour;
        }
        else
        {
            // Crosses midnight
            return currentHour >= ScheduleStartHour || currentHour <= ScheduleEndHour;
        }
    }
}
