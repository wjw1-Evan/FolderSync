using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace FolderSync.Data.Entities;

/// <summary>
/// Represents file metadata for tracking sync status
/// </summary>
public class FileMetadata
{
    [Key]
    [DatabaseGenerated(DatabaseGeneratedOption.Identity)]
    public int Id { get; set; }

    /// <summary>
    /// Relative file path within the sync folder
    /// </summary>
    [Required]
    [MaxLength(2000)]
    public string FilePath { get; set; } = string.Empty;

    /// <summary>
    /// SHA256 hash of file content
    /// </summary>
    [Required]
    [MaxLength(64)]
    public string FileHash { get; set; } = string.Empty;

    /// <summary>
    /// File size in bytes
    /// </summary>
    public long FileSize { get; set; }

    /// <summary>
    /// Last modified timestamp from filesystem
    /// </summary>
    public DateTime LastModified { get; set; }

    /// <summary>
    /// Whether this file has been deleted locally
    /// </summary>
    public bool IsDeleted { get; set; } = false;

    /// <summary>
    /// Foreign key to sync configuration
    /// </summary>
    [Required]
    public int SyncConfigId { get; set; }

    /// <summary>
    /// Navigation property to sync configuration
    /// </summary>
    [ForeignKey(nameof(SyncConfigId))]
    public virtual SyncConfiguration? SyncConfig { get; set; }

    /// <summary>
    /// Navigation property to file versions
    /// </summary>
    public virtual ICollection<FileVersion> Versions { get; set; } = new List<FileVersion>();
}
