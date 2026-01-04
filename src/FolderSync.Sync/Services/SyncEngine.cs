using FolderSync.Core.Models;
using System.Text.Json;
using FolderSync.Core.Interfaces;
using FolderSync.Core.Models.Messages;
using FolderSync.Data;
using FolderSync.Data.Entities;
using Microsoft.EntityFrameworkCore;

namespace FolderSync.Sync.Services;

public interface ISyncEngine
{
    Task StartAsync();
    Task StopAsync();
    Task AddSyncFolderAsync(string localPath);
    event EventHandler<MetadataChangedEventArgs> MetadataChanged;
}

public class MetadataChangedEventArgs : EventArgs
{
    public FileDelta Delta { get; set; } = new();
}

public class SyncEngine : ISyncEngine
{
    private readonly IFileMonitorService _fileMonitor;
    private readonly IDatabaseService _databaseService;
    private readonly IDbContextFactory<FolderSyncDbContext> _dbContextFactory;
    private readonly IHashService _hashService;
    private readonly IVersionManager _versionManager;

    public event EventHandler<MetadataChangedEventArgs>? MetadataChanged;

    public SyncEngine(
        IFileMonitorService fileMonitor,
        IDatabaseService databaseService,
        IDbContextFactory<FolderSyncDbContext> dbContextFactory,
        IHashService hashService,
        IVersionManager versionManager)
    {
        _fileMonitor = fileMonitor;
        _databaseService = databaseService;
        _dbContextFactory = dbContextFactory;
        _hashService = hashService;
        _versionManager = versionManager;

        _fileMonitor.FileChanged += OnFileChanged;
    }

    public async Task StartAsync()
    {
        await _databaseService.InitializeAsync();

        using var db = await _dbContextFactory.CreateDbContextAsync();
        var configs = await db.SyncConfigurations.Where(c => c.SyncEnabled).ToListAsync();

        foreach (var config in configs)
        {
            if (Directory.Exists(config.LocalPath))
            {
                _fileMonitor.StartMonitoring(config.LocalPath);
                // Trigger an async scan
                _ = Task.Run(() => ScanFolderAsync(config.LocalPath, config));
            }
        }
    }

    public Task StopAsync()
    {
        // Stop monitoring logic
        return Task.CompletedTask;
    }

    public async Task AddSyncFolderAsync(string path)
    {
        using var db = await _dbContextFactory.CreateDbContextAsync();
        
        if (await db.SyncConfigurations.AnyAsync(c => c.LocalPath == path))
            return;

        // Create default filter (exclude system/hidden files)
        var defaultFilter = new SyncFilter
        {
            ExcludePatterns = new List<string> { ".DS_Store", "thumbs.db", "*.tmp" }
        };

        var config = new SyncConfiguration
        {
            LocalPath = path,
            SyncEnabled = true,
            Priority = SyncPriority.Medium,
            FilterRules = JsonSerializer.Serialize(defaultFilter)
        };

        db.SyncConfigurations.Add(config);
        await db.SaveChangesAsync();

        _fileMonitor.StartMonitoring(path);
        
        // Initial scan
        _ = Task.Run(() => ScanFolderAsync(path, config));
    }

    private async void OnFileChanged(object? sender, FileChangedEventArgs e)
    {
        try
        {
            using var db = await _dbContextFactory.CreateDbContextAsync();
            
            // Find relevant config
            var config = await db.SyncConfigurations
                .OrderByDescending(c => c.LocalPath.Length)
                .FirstOrDefaultAsync(c => e.FullPath.StartsWith(c.LocalPath));

            if (config == null || !config.SyncEnabled) return;

            // Apply filters
            if (!string.IsNullOrEmpty(config.FilterRules))
            {
                var filter = JsonSerializer.Deserialize<SyncFilter>(config.FilterRules);
                if (filter != null)
                {
                    long size = File.Exists(e.FullPath) ? new FileInfo(e.FullPath).Length : 0;
                    
                    if (File.Exists(e.FullPath) && !filter.IsAllowed(e.FullPath, size))
                    {
                        Console.WriteLine($"Skipping excluded file: {e.FullPath}");
                        return;
                    }
                }
            }

            string relativePath = Path.GetRelativePath(config.LocalPath, e.FullPath);
            
            if (File.Exists(e.FullPath))
            {
                var fileInfo = new FileInfo(e.FullPath);
                var newHash = await _hashService.ComputeFileHashAsync(e.FullPath);

                // Handle versioning
                await _versionManager.CreateVersionAsync(e.FullPath, config.LocalPath, config.Id, newHash);

                // Update or create metadata
                var metadata = await db.FileMetadatas
                    .FirstOrDefaultAsync(m => m.SyncConfigId == config.Id && m.FilePath == relativePath);

                if (metadata == null)
                {
                    metadata = new FileMetadata
                    {
                        SyncConfigId = config.Id,
                        FilePath = relativePath,
                        FileHash = newHash,
                        FileSize = fileInfo.Length,
                        LastModified = fileInfo.LastWriteTimeUtc,
                        IsDeleted = false
                    };
                    db.FileMetadatas.Add(metadata);
                }
                else
                {
                    metadata.FileHash = newHash;
                    metadata.FileSize = fileInfo.Length;
                    metadata.LastModified = fileInfo.LastWriteTimeUtc;
                    metadata.IsDeleted = false;
                }

                db.SyncHistories.Add(new SyncHistory
                {
                    Operation = SyncOperation.Update,
                    FilePath = e.FullPath,
                    Status = SyncStatus.Success,
                    Timestamp = DateTime.UtcNow,
                    FileSize = fileInfo.Length
                });

                await db.SaveChangesAsync();
                
                MetadataChanged?.Invoke(this, new MetadataChangedEventArgs
                {
                    Delta = new FileDelta
                    {
                        FilePath = relativePath,
                        Hash = newHash,
                        Size = fileInfo.Length,
                        IsDeleted = false
                    }
                });
            }
            else
            {
                // File deleted
                var metadata = await db.FileMetadatas
                    .FirstOrDefaultAsync(m => m.SyncConfigId == config.Id && m.FilePath == relativePath);

                if (metadata != null && !metadata.IsDeleted)
                {
                    metadata.IsDeleted = true;
                    
                    db.SyncHistories.Add(new SyncHistory
                    {
                        Operation = SyncOperation.Delete,
                        FilePath = e.FullPath,
                        Status = SyncStatus.Success,
                        Timestamp = DateTime.UtcNow
                    });
                    
                    await db.SaveChangesAsync();
                    
                    MetadataChanged?.Invoke(this, new MetadataChangedEventArgs
                    {
                        Delta = new FileDelta
                        {
                            FilePath = relativePath,
                            IsDeleted = true
                        }
                    });
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error processing file change: {ex.Message}");
        }
    }

    private async Task ScanFolderAsync(string path, SyncConfiguration config)
    {
        try
        {
            var filter = !string.IsNullOrEmpty(config.FilterRules) 
                ? JsonSerializer.Deserialize<SyncFilter>(config.FilterRules) 
                : null;

            foreach (var file in Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories))
            {
                var relativePath = Path.GetRelativePath(path, file);
                var info = new FileInfo(file);

                if (filter != null && !filter.IsAllowed(file, info.Length)) continue;

                // Simulate change event to index existing files
                OnFileChanged(this, new FileChangedEventArgs
                {
                    FullPath = file,
                    ChangeType = WatcherChangeTypes.Created
                });
                
                // Small delay to prevent database lock contention during mass scan
                await Task.Delay(10); 
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error scanning folder {path}: {ex.Message}");
        }
    }
}
