using System.Text.Json;
using FolderSync.Core.Interfaces;
using FolderSync.Core.Models.Messages;
using FolderSync.Data;
using FolderSync.Data.Entities;
using FolderSync.Sync.Models;
using FolderSync.Security.Services;
using Microsoft.EntityFrameworkCore;

namespace FolderSync.Sync.Services;

public interface ISyncCoordinator
{
    Task StartAsync();
    Task StopAsync();
}

public class SyncCoordinator : ISyncCoordinator
{
    private readonly IPeerService _peerService;
    private readonly IDbContextFactory<FolderSyncDbContext> _dbContextFactory;
    private readonly ISyncEngine _syncEngine;
    private readonly IConflictService _conflictService;
    private readonly IFileTransferService _fileTransferService;
    private readonly INatService _natService;
    private readonly INotificationService _notificationService;
    private readonly IHashService _hashService;
    private readonly ICleanupService _cleanupService;
    private readonly IDiskMonitorService _diskMonitor;
    private readonly ISyncQueue _syncQueue;
    private readonly IAnomalyDetectionService _anomalyService;
    private readonly CancellationTokenSource _cts = new();
    private readonly string _deviceId;
    private readonly int _port;
    private readonly int _fileTransferPort;

    public SyncCoordinator(
        IPeerService peerService,
        IDbContextFactory<FolderSyncDbContext> dbContextFactory,
        ISyncEngine syncEngine,
        IFileTransferService fileTransferService,
        IConflictService conflictService,
        INatService natService,
        INotificationService notificationService,
        IHashService hashService,
        ICleanupService cleanupService,
        IDiskMonitorService diskMonitor,
        ISyncQueue syncQueue,
        IAnomalyDetectionService anomalyService,
        string deviceId,
        int port = 5000)
    {
        _peerService = peerService;
        _dbContextFactory = dbContextFactory;
        _syncEngine = syncEngine;
        _fileTransferService = fileTransferService;
        _conflictService = conflictService;
        _natService = natService;
        _notificationService = notificationService;
        _hashService = hashService;
        _cleanupService = cleanupService;
        _diskMonitor = diskMonitor;
        _syncQueue = syncQueue;
        _anomalyService = anomalyService;
        _deviceId = deviceId;
        _port = port;
        _fileTransferPort = port + 2;

        _peerService.MessageReceived += OnMessageReceived;
        _syncEngine.MetadataChanged += OnLocalMetadataChanged;
        _fileTransferService.FileReceived += OnFileReceived;
        _diskMonitor.LowDiskSpaceDetected += (s, space) => 
        {
            _notificationService.ShowNotification("Low Disk Space", $"Warning: Low disk space detected ({space / 1024 / 1024} MB remaining).");
        };

        _anomalyService.AnomalyDetected += (s, e) =>
        {
             _notificationService.ShowNotification($"Anomaly: {e.Severity}", e.Description);
        };
    }

    private async void OnFileReceived(object? sender, FileReceivedEventArgs e)
    {
        try
        {
            if (e.Metadata.IsQuickSend)
            {
                await HandleQuickSendFileReceivedAsync(e);
                return;
            }

            using var db = await _dbContextFactory.CreateDbContextAsync();
            
            // 1. Find the sync config
            var config = await db.SyncConfigurations.FirstOrDefaultAsync(c => c.SyncEnabled);
            if (config == null) return;

            string finalPath = Path.Combine(config.LocalPath, e.Metadata.RelativePath);
            string? directory = Path.GetDirectoryName(finalPath);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);

            bool isConflict = false;
            string targetPath = finalPath;

            // 2. Conflict Detection
            if (File.Exists(finalPath))
            {
                var metadata = await db.FileMetadatas
                    .FirstOrDefaultAsync(m => m.SyncConfigId == config.Id && m.FilePath == e.Metadata.RelativePath);

                if (metadata != null)
                {
                    var currentLocalHash = await _hashService.ComputeFileHashAsync(finalPath);
                    if (currentLocalHash != metadata.FileHash)
                    {
                        // Local file has changed since it was last synced -> CONFLICT
                        isConflict = true;
                        targetPath = _conflictService.GetConflictPath(finalPath);
                        
                        db.SyncConflicts.Add(new SyncConflict
                        {
                            RelativePath = e.Metadata.RelativePath,
                            LocalFilePath = finalPath,
                            RemoteDeviceId = e.Metadata.DeviceId ?? "Unknown",
                            LocalHash = currentLocalHash,
                            RemoteHash = e.Metadata.Hash,
                            ConflictTime = DateTime.UtcNow,
                            Resolution = ConflictResolution.Pending,
                            ResolvedFilePath = targetPath
                        });

                        _notificationService.ShowNotification("Sync Conflict", $"Conflict detected for {e.Metadata.RelativePath}. Both versions preserved.");
                    }
                }
            }

            // 3. Move file
            if (!isConflict && File.Exists(finalPath)) File.Delete(finalPath);
            File.Move(e.TempPath, targetPath);

            // 4. Update Metadata
            var existingMetadata = await db.FileMetadatas
                .FirstOrDefaultAsync(m => m.SyncConfigId == config.Id && m.FilePath == e.Metadata.RelativePath);

            if (!isConflict || existingMetadata == null)
            {
                if (existingMetadata == null)
                {
                    existingMetadata = new FileMetadata
                    {
                        SyncConfigId = config.Id,
                        FilePath = e.Metadata.RelativePath,
                        FileHash = e.Metadata.Hash,
                        FileSize = e.Metadata.Size,
                        LastModified = DateTime.UtcNow,
                        IsDeleted = false
                    };
                    db.FileMetadatas.Add(existingMetadata);
                }
                else
                {
                    existingMetadata.FileHash = e.Metadata.Hash;
                    existingMetadata.FileSize = e.Metadata.Size;
                    existingMetadata.LastModified = DateTime.UtcNow;
                    existingMetadata.IsDeleted = false;
                }
            }

            db.SyncHistories.Add(new SyncHistory
            {
                Operation = isConflict ? SyncOperation.Add : SyncOperation.Update,
                FilePath = targetPath,
                Status = SyncStatus.Success,
                Timestamp = DateTime.UtcNow,
                SourceDeviceId = e.Metadata.DeviceId,
                FileSize = e.Metadata.Size,
                ErrorMessage = isConflict ? "Conflict saved as separate file" : null
            });

            await db.SaveChangesAsync();
            Console.WriteLine($"Successfully received and processed {e.Metadata.RelativePath}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error processing received file: {ex.Message}");
        }
    }

    public async Task StartAsync()
    {
        await _peerService.StartAsync();
        await _fileTransferService.StartListenerAsync(_fileTransferPort);
        
        // Map ports for external access
        await _natService.MapPortAsync(_port + 1, "FolderSync Messaging");
        await _natService.MapPortAsync(_fileTransferPort, "FolderSync Transfer");

        // Run cleanup
        _ = Task.Run(async () => 
        {
            while (true)
            {
                await _cleanupService.CleanupAsync();
                await _cleanupService.CleanupTempFilesAsync();
                await _diskMonitor.CheckDiskSpaceAsync();
                await Task.Delay(TimeSpan.FromHours(24));
            }
        });

        // Start Queue Workers (3 threads)
        for (int i = 0; i < 3; i++)
        {
            _ = Task.Run(() => ProcessQueueAsync(_cts.Token));
        }
    }

    public async Task StopAsync()
    {
        _cts.Cancel();
        await _peerService.StopAsync();
        _fileTransferService.StopListener();
        
        await _natService.UnmapPortAsync(_port + 1);
        await _natService.UnmapPortAsync(_fileTransferPort);
    }

    private async void OnLocalMetadataChanged(object? sender, MetadataChangedEventArgs e)
    {
        using var db = await _dbContextFactory.CreateDbContextAsync();
        var config = await db.SyncConfigurations.FirstOrDefaultAsync(c => c.SyncEnabled);
        if (config == null || !config.IsInScheduleWindow()) return;

        var msg = new SyncMetaMessage
        {
            SenderDeviceId = _deviceId,
            Deltas = new List<FileDelta> { e.Delta }
        };
        await _peerService.SendMessageAsync(msg);
    }

    private async void OnMessageReceived(object? sender, MessageReceivedEventArgs e)
    {
        try
        {
            var baseMsg = JsonSerializer.Deserialize<BaseMessage>(e.MessageJson);
            if (baseMsg == null) return;

            switch (baseMsg.Type)
            {
                case MessageType.Handshake:
                    await HandleHandshakeAsync(e.MessageJson);
                    break;
                case MessageType.SyncMeta:
                    await HandleSyncMetaAsync(e, e.MessageJson);
                    break;
                case MessageType.FileRequest:
                    await HandleFileRequestAsync(e, e.MessageJson);
                    break;
                case MessageType.QuickSend:
                    await HandleQuickSendAsync(e, e.MessageJson);
                    break;
                case MessageType.PairingRequest:
                    await HandlePairingRequestAsync(e, e.MessageJson);
                    break;
                case MessageType.PairingResponse:
                    await HandlePairingResponseAsync(e, e.MessageJson);
                    break;
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error handling message: {ex.Message}");
        }
    }

    private async Task HandleHandshakeAsync(string json)
    {
        var msg = JsonSerializer.Deserialize<HandshakeMessage>(json);
        if (msg == null) return;
        Console.WriteLine($"Handshake from {msg.DeviceName} ({msg.SenderDeviceId})");
    }

    private async Task HandleSyncMetaAsync(MessageReceivedEventArgs e, string json)
    {
        var msg = JsonSerializer.Deserialize<SyncMetaMessage>(json);
        if (msg == null) return;

        using var db = await _dbContextFactory.CreateDbContextAsync();
        
        // 0. Check Peer Permission
        var peer = await db.PeerDevices.FirstOrDefaultAsync(p => p.DeviceId == msg.SenderDeviceId);
        if (peer != null)
        {
            if (peer.AccessLevel == DeviceAccessLevel.Blocked)
            {
                Console.WriteLine($"Ignored sync meta from blocked device: {peer.DeviceName}");
                return;
            }
        }

        foreach (var delta in msg.Deltas)
        {
            // If ReadOnly, we don't allow them to trigger deletions or modifications here 
            // (Strictly speaking, SyncMeta usually means "this is my current state, you decide")
            // But if we are the ones enforcing, we check if we should even process this delta.
            
            if (peer != null && peer.AccessLevel == DeviceAccessLevel.ReadOnly)
            {
                // In Read-Only mode, we might only allow DOWNLOADS if we want, 
                // but usually Read-Only means "Treat this peer as a source only, don't let it change us".
                // For now, if ReadOnly, we skip processing their deltas if it would cause a local change 
                // that isn't just "receiving a new file".
                // Actually, let's keep it simple: ReadOnly peer can only be downloaded FROM.
            }

            var existing = await db.FileMetadatas
                .Include(m => m.SyncConfig)
                .FirstOrDefaultAsync(m => m.FilePath == delta.FilePath);

            // Respect Schedule
            if (existing?.SyncConfig != null && !existing.SyncConfig.IsInScheduleWindow())
            {
                Console.WriteLine($"Skipping sync for {delta.FilePath} - outside of scheduled window.");
                continue;
            }

            if (existing == null)
            {
                // New file from remote
                _syncQueue.Enqueue(new SyncTask
                {
                    FilePath = delta.FilePath,
                    TargetIp = e.SenderIp,
                    Type = SyncTaskType.Download,
                    Priority = existing?.SyncConfig?.Priority ?? SyncPriority.Medium,
                    Hash = delta.Hash
                });
            }
            else if (existing.SyncConfig != null && existing.FileHash != delta.Hash && !delta.IsDeleted)
            {
                // Modification.
                _syncQueue.Enqueue(new SyncTask
                {
                    FilePath = delta.FilePath,
                    TargetIp = e.SenderIp,
                    Type = SyncTaskType.Download,
                    Priority = existing.SyncConfig.Priority,
                    Hash = delta.Hash
                });
            }
            else if (existing != null && delta.IsDeleted)
            {
                if (peer?.AccessLevel == DeviceAccessLevel.ReadOnly)
                {
                    Console.WriteLine($"Ignoring deletion request from ReadOnly device: {peer.DeviceName} for {delta.FilePath}");
                    continue;
                }

                // Remote file deleted
                // 1. Record Anomaly Event
                await _anomalyService.RecordEventAsync("FileDelete", e.SenderIp, delta.FilePath);

                // 2. Perform deletion (Logic simplified: direct delete or queue)
                // For now, we won't auto-delete without a stronger sync engine, 
                // but we record the event as per task requirement.
                Console.WriteLine($"Remote deletion detected for {delta.FilePath}");
            }
        }
    }

    private async Task ProcessQueueAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            var task = _syncQueue.Dequeue();
            if (task == null)
            {
                await Task.Delay(1000, ct);
                continue;
            }

            try
            {
                if (task.Type == SyncTaskType.Download)
                {
                    var delta = new FileDelta { FilePath = task.FilePath, Hash = task.Hash ?? "" };
                    await RequestFileAsync(task.TargetIp, delta, task.IsQuickSend);
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Error processing sync task: {ex.Message}");
                if (task.RetryCount < 3)
                {
                    task.RetryCount++;
                    _syncQueue.Enqueue(task);
                }
            }
        }
    }

    private async Task RequestFileAsync(string senderIp, FileDelta delta, bool isQuickSend = false)
    {
        string tempDir = Path.Combine(Path.GetTempPath(), "FolderSync");
        string tempPath = Path.Combine(tempDir, $"{delta.Hash}.part");
        long offset = 0;

        if (File.Exists(tempPath))
        {
            var info = new FileInfo(tempPath);
            offset = info.Length;
        }

        var request = new FileRequestMessage
        {
            SenderDeviceId = _deviceId,
            FilePath = delta.FilePath,
            ExpectedHash = delta.Hash,
            RequestedOffset = offset,
            IsQuickSend = isQuickSend
        };
        
        await _peerService.SendToPeerAsync(senderIp, 5001, request);
    }

    private async Task HandleFileRequestAsync(MessageReceivedEventArgs e, string json)
    {
        var msg = JsonSerializer.Deserialize<FileRequestMessage>(json);
        if (msg == null) return;

        string? fullPath = null;
        if (msg.IsQuickSend)
        {
            fullPath = msg.FilePath;
        }
        else
        {
            using var db = await _dbContextFactory.CreateDbContextAsync();
            var metadata = await db.FileMetadatas
                .Include(m => m.SyncConfig)
                .FirstOrDefaultAsync(m => m.FilePath == msg.FilePath);

            if (metadata?.SyncConfig != null)
            {
                fullPath = Path.Combine(metadata.SyncConfig.LocalPath, metadata.FilePath);
            }
        }

        if (fullPath != null && File.Exists(fullPath))
        {
            await _fileTransferService.SendFileAsync(fullPath, msg.FilePath, e.SenderIp, 5002, _deviceId, msg.RequestedOffset, msg.IsQuickSend);
        }
    }
    private async Task HandleQuickSendAsync(MessageReceivedEventArgs e, string json)
    {
        var msg = JsonSerializer.Deserialize<QuickSendMessage>(json);
        if (msg == null) return;

        // Auto-accept for now, showing notification
        _notificationService.ShowNotification("Quick Send Received", $"Receiving {msg.FileName} from {e.SenderIp}");

        _syncQueue.Enqueue(new SyncTask
        {
            FilePath = msg.FileName,
            TargetIp = e.SenderIp,
            Type = SyncTaskType.Download,
            Priority = SyncPriority.High, // Quick send is high priority
            Hash = msg.Hash,
            IsQuickSend = true
        });
    }

    private async Task HandleQuickSendFileReceivedAsync(FileReceivedEventArgs e)
    {
        string downloadDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "FolderSync");
        if (!Directory.Exists(downloadDir)) Directory.CreateDirectory(downloadDir);

        string finalPath = Path.Combine(downloadDir, e.Metadata.RelativePath);
        if (File.Exists(finalPath)) File.Delete(finalPath);
        File.Move(e.TempPath, finalPath);

        _notificationService.ShowNotification("Quick Send Complete", $"Received {e.Metadata.RelativePath} in Downloads/FolderSync");
    }

    private async Task HandlePairingRequestAsync(MessageReceivedEventArgs e, string json)
    {
        var msg = JsonSerializer.Deserialize<PairingRequestMessage>(json);
        if (msg == null) return;

        _notificationService.ShowNotification("Pairing Request", $"Device {msg.DeviceName} wants to pair. Go to Devices to approve.");
        
        // In a real app, we might store this 'Pending' state in DB so UI can show it.
        // For now, if the user manually marks it as Trusted in UI, we can consider that an "Approval" if we match it.
        // Or we can auto-create the peer as Untrusted.
        
        using var db = await _dbContextFactory.CreateDbContextAsync();
        var peer = await db.PeerDevices.FirstOrDefaultAsync(p => p.DeviceId == msg.SenderDeviceId);
        if (peer == null)
        {
            peer = new PeerDevice
            {
                DeviceId = msg.SenderDeviceId,
                DeviceName = msg.DeviceName,
                IsTrusted = false, // Default to false
                LastSeen = DateTime.UtcNow,
                IpAddress = e.SenderIp
            };
            db.PeerDevices.Add(peer);
            await db.SaveChangesAsync();
        }
    }

    private async Task HandlePairingResponseAsync(MessageReceivedEventArgs e, string json)
    {
        var msg = JsonSerializer.Deserialize<PairingResponseMessage>(json);
        if (msg == null) return;

        if (msg.Approved)
        {
            _notificationService.ShowNotification("Pairing Accepted", $"Device accepted your pairing request.");
            
            using var db = await _dbContextFactory.CreateDbContextAsync();
            var peer = await db.PeerDevices.FirstOrDefaultAsync(p => p.DeviceId == msg.SenderDeviceId);
            if (peer != null)
            {
                peer.IsTrusted = true;
                db.PeerDevices.Update(peer);
                await db.SaveChangesAsync();
            }
        }
        else
        {
             _notificationService.ShowNotification("Pairing Denied", $"Device denied your pairing request: {msg.Reason}");
        }
    }
}
