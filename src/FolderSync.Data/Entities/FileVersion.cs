using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace FolderSync.Data.Entities;

/// <summary>
/// Represents a historical version of a file
/// </summary>
public class FileVersion
{
    [Key]
    [DatabaseGenerated(DatabaseGeneratedOption.Identity)]
    public int Id { get; set; }

    /// <summary>
    /// Foreign key to file metadata
    /// </summary>
    [Required]
    public int FileMetadataId { get; set; }

    /// <summary>
    /// Version number (incremental)
    /// </summary>
    public int VersionNumber { get; set; }

    /// <summary>
    /// SHA256 hash of this version
    /// </summary>
    [Required]
    [MaxLength(64)]
    public string VersionHash { get; set; } = string.Empty;

    /// <summary>
    /// Path to archived version file
    /// </summary>
    [Required]
    [MaxLength(2000)]
    public string FilePath { get; set; } = string.Empty;

    /// <summary>
    /// File size in bytes
    /// </summary>
    public long FileSize { get; set; }

    /// <summary>
    /// When this version was created
    /// </summary>
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;

    /// <summary>
    /// Optional note/comment for this version
    /// </summary>
    [MaxLength(500)]
    public string? Note { get; set; }

    /// <summary>
    /// Navigation property to file metadata
    /// </summary>
    [ForeignKey(nameof(FileMetadataId))]
    public virtual FileMetadata? FileMetadata { get; set; }
}
