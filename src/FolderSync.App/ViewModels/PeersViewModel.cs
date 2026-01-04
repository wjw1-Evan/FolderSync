using System.Collections.ObjectModel;
using System.Windows.Input;
using FolderSync.Core.Interfaces;
using FolderSync.Data;
using FolderSync.Data.Entities;
using Microsoft.EntityFrameworkCore;
using FolderSync.App.Services;
using FolderSync.Core.Models.Messages;

namespace FolderSync.App.ViewModels;

public class PeersViewModel : BaseViewModel
{
    private readonly IDbContextFactory<FolderSyncDbContext> _dbFactory;
    private readonly IPeerService _peerService;
    private readonly ILocalizationService _localizationService;
    private ObservableCollection<PeerDevice> _peers = new();

    public PeersViewModel(IDbContextFactory<FolderSyncDbContext> dbFactory, IPeerService peerService, ILocalizationService localizationService)
    {
        _dbFactory = dbFactory;
        _peerService = peerService;
        _localizationService = localizationService;
        Title = _localizationService["Devices"];
        
        LoadPeersCommand = new Command(async () => await LoadPeersAsync());
        ToggleTrustCommand = new Command<PeerDevice>(async (p) => await ToggleTrustAsync(p));
        UpdateAccessLevelCommand = new Command<PeerDevice>(async (p) => await UpdateAccessLevelAsync(p));
    }

    public ObservableCollection<PeerDevice> Peers
    {
        get => _peers;
        set => SetProperty(ref _peers, value);
    }

    public ICommand LoadPeersCommand { get; }
    public ICommand ToggleTrustCommand { get; }
    public ICommand UpdateAccessLevelCommand { get; }

    public List<DeviceAccessLevel> AccessLevels { get; } = Enum.GetValues<DeviceAccessLevel>().ToList();

    public async Task LoadPeersAsync()
    {
        IsBusy = true;
        try
        {
            using var db = await _dbFactory.CreateDbContextAsync();
            var peers = await db.PeerDevices.OrderByDescending(p => p.LastSeen).ToListAsync();
            
            // Check current online status from PeerService
            foreach (var peer in peers)
            {
                peer.IsOnline = _peerService.IsPeerOnline(peer.DeviceId);
            }
            
            Peers = new ObservableCollection<PeerDevice>(peers);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error loading peers: {ex.Message}");
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task ToggleTrustAsync(PeerDevice peer)
    {
        if (peer == null) return;

        peer.IsTrusted = !peer.IsTrusted;
        
        using var db = await _dbFactory.CreateDbContextAsync();
        db.PeerDevices.Update(peer);
        
        // Get Local Identity
        var identity = await db.ClientIdentities.FirstOrDefaultAsync();
        string myName = identity?.DeviceName ?? "FolderSync Device";

        await db.SaveChangesAsync();
        
        // Update local list
        OnPropertyChanged(nameof(Peers));

        // Send Pairing Message if online
        if (peer.IsOnline && !string.IsNullOrEmpty(peer.IpAddress))
        {
            if (peer.IsTrusted)
            {
                // We just trusted them. 
                // 1. Send Response (Approved) in case they asked.
                // 2. Send Request (Asking them to trust us)
                
                var response = new PairingResponseMessage { Approved = true, SenderDeviceId = identity?.ClientId ?? "Unknown" };
                await _peerService.SendToPeerAsync(peer.IpAddress, peer.Port ?? 5001, response);

                var request = new PairingRequestMessage { DeviceName = myName, SenderDeviceId = identity?.ClientId ?? "Unknown" };
                await _peerService.SendToPeerAsync(peer.IpAddress, peer.Port ?? 5001, request);
            }
            else
            {
                // We untrusted them.
                var response = new PairingResponseMessage { Approved = false, Reason = "User revoked trust", SenderDeviceId = identity?.ClientId ?? "Unknown" };
                await _peerService.SendToPeerAsync(peer.IpAddress, peer.Port ?? 5001, response);
            }
        }
    }

    private async Task UpdateAccessLevelAsync(PeerDevice peer)
    {
        if (peer == null) return;

        using var db = await _dbFactory.CreateDbContextAsync();
        db.PeerDevices.Update(peer);
        await db.SaveChangesAsync();
        
        Console.WriteLine($"Access level updated for {peer.DeviceName} to {peer.AccessLevel}");
    }
}
