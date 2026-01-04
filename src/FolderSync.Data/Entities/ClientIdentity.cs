using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace FolderSync.Data.Entities;

/// <summary>
/// Represents a client identity with encrypted credentials
/// </summary>
public class ClientIdentity
{
    [Key]
    [DatabaseGenerated(DatabaseGeneratedOption.Identity)]
    public int Id { get; set; }

    /// <summary>
    /// Client ID (encrypted in database)
    /// </summary>
    [Required]
    [MaxLength(256)]
    public string ClientId { get; set; } = string.Empty;

    /// <summary>
    /// Password hash (using PBKDF2 or bcrypt)
    /// </summary>
    [Required]
    [MaxLength(256)]
    public string PasswordHash { get; set; } = string.Empty;

    /// <summary>
    /// Local device name
    /// </summary>
    [Required]
    [MaxLength(100)]
    public string DeviceName { get; set; } = string.Empty;

    /// <summary>
    /// When this identity was created
    /// </summary>
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;

    /// <summary>
    /// Last time credentials were modified
    /// </summary>
    public DateTime LastModifiedAt { get; set; } = DateTime.UtcNow;
}
