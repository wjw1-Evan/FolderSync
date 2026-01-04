using Microsoft.EntityFrameworkCore;

namespace FolderSync.Data;

public interface IDatabaseService
{
    Task InitializeAsync();
}

public class DatabaseService : IDatabaseService
{
    private readonly FolderSyncDbContext _dbContext;

    public DatabaseService(FolderSyncDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task InitializeAsync()
    {
        // Ensure directory exists
        var dbPath = _dbContext.Database.GetDbConnection().DataSource;
        var directory = Path.GetDirectoryName(dbPath);
        if (!string.IsNullOrEmpty(directory) && !Directory.Exists(directory))
        {
            Directory.CreateDirectory(directory);
        }

        // Apply migrations or create database
        await _dbContext.Database.EnsureCreatedAsync();
        
        // In the future, use: await _dbContext.Database.MigrateAsync();
    }
}
