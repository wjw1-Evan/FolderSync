using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace FolderSync.Data.Entities;

public enum ConflictResolution
{
    Pending = 0,
    KeptLocal = 1,
    KeptRemote = 2,
    KeptBoth = 3,
    Ignored = 4
}

public class SyncConflict
{
    [Key]
    [DatabaseGenerated(DatabaseGeneratedOption.Identity)]
    public int Id { get; set; }

    [Required]
    [MaxLength(2000)]
    public string RelativePath { get; set; } = string.Empty;

    public string LocalFilePath { get; set; } = string.Empty;
    public string RemoteDeviceId { get; set; } = string.Empty;

    public string? LocalHash { get; set; }
    public string? RemoteHash { get; set; }

    public DateTime ConflictTime { get; set; } = DateTime.UtcNow;

    public ConflictResolution Resolution { get; set; } = ConflictResolution.Pending;

    public string? ResolvedFilePath { get; set; }
}
