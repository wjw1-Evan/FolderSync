using FolderSync.Data;
using Microsoft.EntityFrameworkCore;

namespace FolderSync.Sync.Services;

public interface ICleanupService
{
    Task CleanupAsync(int daysToKeep = 30);
    Task CleanupTempFilesAsync();
}

public class CleanupService : ICleanupService
{
    private readonly IDbContextFactory<FolderSyncDbContext> _dbFactory;

    public CleanupService(IDbContextFactory<FolderSyncDbContext> dbFactory)
    {
        _dbFactory = dbFactory;
    }

    public async Task CleanupAsync(int daysToKeep = 30)
    {
        try
        {
            using var db = await _dbFactory.CreateDbContextAsync();
            var cutoff = DateTime.UtcNow.AddDays(-daysToKeep);

            var oldHistory = await db.SyncHistories
                .Where(h => h.Timestamp < cutoff)
                .ToListAsync();

            if (oldHistory.Any())
            {
                db.SyncHistories.RemoveRange(oldHistory);
                await db.SaveChangesAsync();
                Console.WriteLine($"Cleaned up {oldHistory.Count} old history records.");
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error during database cleanup: {ex.Message}");
        }
    }

    public async Task CleanupTempFilesAsync()
    {
        try
        {
            string tempDir = Path.Combine(Path.GetTempPath(), "FolderSync");
            if (Directory.Exists(tempDir))
            {
                var files = Directory.GetFiles(tempDir, "*.part");
                foreach (var file in files)
                {
                    var info = new FileInfo(file);
                    // Remove if older than 24 hours
                    if (info.LastWriteTimeUtc < DateTime.UtcNow.AddDays(-1))
                    {
                        File.Delete(file);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error during temp file cleanup: {ex.Message}");
        }
    }
}
