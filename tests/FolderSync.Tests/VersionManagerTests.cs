using FolderSync.Data;
using FolderSync.Data.Entities;
using FolderSync.Sync.Services;
using Microsoft.EntityFrameworkCore;
using Xunit;

namespace FolderSync.Tests;

public class VersionManagerTests
{
    private readonly string _tempDir;
    private readonly VersionManager _versionManager;
    private readonly IDbContextFactory<FolderSyncDbContext> _dbFactory;
    private readonly Microsoft.Data.Sqlite.SqliteConnection _connection;

    public VersionManagerTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        Directory.CreateDirectory(_tempDir);

        // Setup persistent in-memory SQLite
        _connection = new Microsoft.Data.Sqlite.SqliteConnection("DataSource=:memory:");
        _connection.Open();

        var options = new DbContextOptionsBuilder<FolderSyncDbContext>()
            .UseSqlite(_connection)
            .Options;

        var mockFactory = new Moq.Mock<IDbContextFactory<FolderSyncDbContext>>();
        mockFactory.Setup(f => f.CreateDbContextAsync(default)).Returns(async () => 
        {
            var db = new FolderSyncDbContext(options);
            await db.Database.EnsureCreatedAsync();
            return db;
        });

        _dbFactory = mockFactory.Object;
        _versionManager = new VersionManager(_dbFactory);
    }

    [Fact]
    public async Task CreateVersionAsync_ArchivesFileWhenMetadataExists()
    {
        int configId;
        // 1. Arrange: Create metadata in DB
        using (var db = await _dbFactory.CreateDbContextAsync())
        {
            var config = new SyncConfiguration { LocalPath = _tempDir, SyncEnabled = true };
            db.SyncConfigurations.Add(config);
            await db.SaveChangesAsync();
            configId = config.Id;

            var metadata = new FileMetadata 
            { 
                SyncConfigId = configId, 
                FilePath = "test.txt", 
                FileHash = "old-hash",
                FileSize = 100 
            };
            db.FileMetadatas.Add(metadata);
            await db.SaveChangesAsync();
        }

        string testFile = Path.Combine(_tempDir, "test.txt");
        File.WriteAllText(testFile, "modified content");

        // 2. Act
        var result = await _versionManager.CreateVersionAsync(testFile, _tempDir, configId, "new-hash");

        // 3. Assert
        Assert.NotNull(result);
        Assert.True(File.Exists(result.FilePath));
        Assert.Contains("test.txt", result.FilePath);

        Directory.Delete(_tempDir, true);
    }
}
