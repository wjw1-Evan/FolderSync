using FolderSync.Data.Entities;

namespace FolderSync.Sync.Services;

public interface IVersionManager
{
    /// <summary>
    /// Creates a new version of a file if it has changed.
    /// </summary>
    Task<FileVersion?> CreateVersionAsync(string fullPath, string configLocalPath, int syncConfigId, string newHash);

    /// <summary>
    /// Restores a specific version of a file.
    /// </summary>
    Task RestoreVersionAsync(int versionId, string targetPath);

    /// <summary>
    /// Cleans up old versions based on retention policy.
    /// </summary>
    Task CleanupVersionsAsync(int syncConfigId);
    
    /// <summary>
    /// Updates the note for a specific version.
    /// </summary>
    Task UpdateVersionNoteAsync(int versionId, string note);
}
