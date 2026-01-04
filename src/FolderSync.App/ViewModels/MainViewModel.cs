using System.Collections.ObjectModel;
using FolderSync.Core.Interfaces;
using FolderSync.Data;
using FolderSync.Data.Entities;
using FolderSync.Sync.Services;
using Microsoft.EntityFrameworkCore;

namespace FolderSync.App.ViewModels;

public class MainViewModel : BaseViewModel
{
    private readonly IDbContextFactory<FolderSyncDbContext> _dbContextFactory;
    private readonly ISyncEngine _syncEngine;
    private readonly IPeerService _peerService;
    private readonly IFileTransferService _fileTransferService;

    public ObservableCollection<SyncConfiguration> SyncFolders { get; } = new();
    public ObservableCollection<PeerDiscoveredEventArgs> DiscoveredPeers { get; } = new();

    private string _statusMessage = "Ready";
    public string StatusMessage
    {
        get => _statusMessage;
        set => SetProperty(ref _statusMessage, value);
    }

    private string _transferProgress = "";
    public string TransferProgress
    {
        get => _transferProgress;
        set => SetProperty(ref _transferProgress, value);
    }

    public MainViewModel(
        IDbContextFactory<FolderSyncDbContext> dbContextFactory,
        ISyncEngine syncEngine,
        IPeerService peerService,
        IFileTransferService fileTransferService)
    {
        _dbContextFactory = dbContextFactory;
        _syncEngine = syncEngine;
        _peerService = peerService;
        _fileTransferService = fileTransferService;

        Title = "FolderSync";
        
        _peerService.PeerDiscovered += (s, e) => 
            MainThread.BeginInvokeOnMainThread(() => DiscoveredPeers.Add(e));
            
        _fileTransferService.TransferProgress += (s, e) =>
            MainThread.BeginInvokeOnMainThread(() => 
                TransferProgress = $"Transferring {e.FileName}: {e.BytesTransferred / 1024} KB / {e.TotalBytes / 1024} KB");
    }

    public async Task InitializeAsync()
    {
        using var db = await _dbContextFactory.CreateDbContextAsync();
        var folders = await db.SyncConfigurations.ToListAsync();
        
        SyncFolders.Clear();
        foreach (var f in folders)
        {
            SyncFolders.Add(f);
        }
    }

    public async Task AddFolderAsync(string path)
    {
        if (string.IsNullOrEmpty(path)) return;

        await _syncEngine.AddSyncFolderAsync(path);
        await InitializeAsync();
    }
}
