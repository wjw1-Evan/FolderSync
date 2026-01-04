using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace FolderSync.Data.Entities;

public enum DeviceAccessLevel
{
    FullSync = 0,    // Read & Write
    ReadOnly = 1,    // We can only download from them, they can't trigger deletes or writes here
    Blocked = 2      // No sync allowed
}

/// <summary>
/// Represents a discovered peer device
/// </summary>
public class PeerDevice
{
    [Key]
    [DatabaseGenerated(DatabaseGeneratedOption.Identity)]
    public int Id { get; set; }

    /// <summary>
    /// Unique device identifier
    /// </summary>
    [Required]
    [MaxLength(256)]
    public string DeviceId { get; set; } = string.Empty;

    /// <summary>
    /// Friendly device name
    /// </summary>
    [Required]
    [MaxLength(100)]
    public string DeviceName { get; set; } = string.Empty;

    /// <summary>
    /// Last time this device was seen online
    /// </summary>
    public DateTime LastSeen { get; set; } = DateTime.UtcNow;

    /// <summary>
    /// Whether device is currently online
    /// </summary>
    public bool IsOnline { get; set; } = false;

    /// <summary>
    /// Last known IP address
    /// </summary>
    [MaxLength(45)] // IPv6 max length
    public string? IpAddress { get; set; }

    /// <summary>
    /// Last known port
    /// </summary>
    public int? Port { get; set; }

    /// <summary>
    /// Whether this device has been manually added
    /// </summary>
    public bool IsManuallyAdded { get; set; } = false;

    /// <summary>
    /// Whether this device is trusted
    /// </summary>
    public bool IsTrusted { get; set; } = false;

    /// <summary>
    /// Permission level for this device
    /// </summary>
    public DeviceAccessLevel AccessLevel { get; set; } = DeviceAccessLevel.FullSync;
}
