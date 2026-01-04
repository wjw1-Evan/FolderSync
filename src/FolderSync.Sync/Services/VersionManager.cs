using FolderSync.Data;
using FolderSync.Data.Entities;
using Microsoft.EntityFrameworkCore;

namespace FolderSync.Sync.Services;

public class VersionManager : IVersionManager
{
    private readonly IDbContextFactory<FolderSyncDbContext> _dbContextFactory;
    private const int MaxVersions = 10; // Default policy

    public VersionManager(IDbContextFactory<FolderSyncDbContext> dbContextFactory)
    {
        _dbContextFactory = dbContextFactory;
    }

    public async Task<FileVersion?> CreateVersionAsync(string fullPath, string configLocalPath, int syncConfigId, string newHash)
    {
        using var db = await _dbContextFactory.CreateDbContextAsync();

        // Get relative path
        string relativePath = Path.GetRelativePath(configLocalPath, fullPath);

        // Find existing metadata
        var metadata = await db.FileMetadatas
            .Include(f => f.Versions)
            .FirstOrDefaultAsync(f => f.SyncConfigId == syncConfigId && f.FilePath == relativePath);

        if (metadata == null)
        {
            // First time seeing this file, no version to archive yet
            return null;
        }

        if (metadata.FileHash == newHash)
        {
            // No change, no new version needed
            return null;
        }

        // Create version from current state (before updating metadata)
        string versionDir = Path.Combine(configLocalPath, ".FolderSync", "Versions", relativePath);
        if (!Directory.Exists(versionDir))
        {
            Directory.CreateDirectory(versionDir);
        }

        string timestamp = DateTime.Now.ToString("yyyyMMddHHmmss");
        int versionNumber = (metadata.Versions.Max(v => (int?)v.VersionNumber) ?? 0) + 1;
        string versionFileName = $"{Path.GetFileName(fullPath)}_{versionNumber}_{timestamp}";
        string versionPath = Path.Combine(versionDir, versionFileName);

        // Copy current file to version storage
        if (File.Exists(fullPath))
        {
            File.Copy(fullPath, versionPath, true);
        }

        var newVersion = new FileVersion
        {
            FileMetadataId = metadata.Id,
            VersionNumber = versionNumber,
            VersionHash = metadata.FileHash,
            FilePath = versionPath,
            FileSize = metadata.FileSize,
            CreatedAt = DateTime.UtcNow
        };

        db.FileVersions.Add(newVersion);
        await db.SaveChangesAsync();

        await CleanupVersionsAsync(metadata.Id, db);

        return newVersion;
    }

    public async Task RestoreVersionAsync(int versionId, string targetPath)
    {
        using var db = await _dbContextFactory.CreateDbContextAsync();
        var version = await db.FileVersions.FindAsync(versionId);
        if (version != null && File.Exists(version.FilePath))
        {
            File.Copy(version.FilePath, targetPath, true);
        }
    }

    public async Task CleanupVersionsAsync(int syncConfigId)
    {
        // This variant is for bulk cleanup if needed
    }

    private async Task CleanupVersionsAsync(int fileMetadataId, FolderSyncDbContext db)
    {
        var versions = await db.FileVersions
            .Where(v => v.FileMetadataId == fileMetadataId)
            .OrderByDescending(v => v.VersionNumber)
            .Skip(MaxVersions)
            .ToListAsync();

        foreach (var v in versions)
        {
            if (File.Exists(v.FilePath))
            {
                File.Delete(v.FilePath);
            }
            db.FileVersions.Remove(v);
        }

        if (versions.Any())
        {
            await db.SaveChangesAsync();
        }
    }

    public async Task UpdateVersionNoteAsync(int versionId, string note)
    {
        using var db = await _dbContextFactory.CreateDbContextAsync();
        var version = await db.FileVersions.FindAsync(versionId);
        if (version != null)
        {
            version.Note = note;
            await db.SaveChangesAsync();
        }
    }
}
