using Microsoft.Extensions.Logging;
using FolderSync.Core;
using FolderSync.Core.Interfaces;
using FolderSync.Data;
using FolderSync.Security.Services;
using FolderSync.P2P.Services;
using FolderSync.Sync.Services;
using FolderSync.App.ViewModels;
using FolderSync.App.Services;
using Microsoft.EntityFrameworkCore;

namespace FolderSync.App;

public static class MauiProgram
{
	public static MauiApp CreateMauiApp()
	{
		var builder = MauiApp.CreateBuilder();
		builder
			.UseMauiApp<App>()
			.ConfigureFonts(fonts =>
			{
				fonts.AddFont("OpenSans-Regular.ttf", "OpenSansRegular");
				fonts.AddFont("OpenSans-Semibold.ttf", "OpenSansSemibold");
			});

        // 1. Data Layer
        builder.Services.AddDbContextFactory<FolderSyncDbContext>(options =>
            options.UseSqlite($"Data Source={DatabaseConstants.DatabasePath}"));
        builder.Services.AddSingleton<IDatabaseService, DatabaseService>();

        // 2. Security Layer
        builder.Services.AddSingleton<IHashService, HashService>();
        builder.Services.AddSingleton<IEncryptionService, EncryptionService>();

        // 3. P2P Layer
        // For now, using device name as ID - in real app, load from DB
        string deviceId = Guid.NewGuid().ToString(); 
        string deviceName = DeviceInfo.Current.Name;
        builder.Services.AddSingleton<IPeerService>(sp => 
            new PeerService(deviceId, deviceName));
        builder.Services.AddSingleton<INatService, NatService>();

        // 4. Sync Layer
        builder.Services.AddSingleton<IFileMonitorService, FileMonitorService>();
        builder.Services.AddSingleton<IVersionManager, VersionManager>();
        builder.Services.AddSingleton<INotificationService, NotificationService>();
        builder.Services.AddSingleton<IConflictService, ConflictService>();
        builder.Services.AddSingleton<ISyncEngine, SyncEngine>();
        builder.Services.AddSingleton<IFileTransferService, FileTransferService>();
        builder.Services.AddSingleton<ICleanupService, CleanupService>();
        builder.Services.AddSingleton<IDiskMonitorService, DiskMonitorService>();
        builder.Services.AddSingleton<ISyncQueue, SyncQueueService>();
        builder.Services.AddSingleton<FolderSync.Core.Interfaces.ISecureStorage, MauiSecureStorage>();
        builder.Services.AddSingleton<ILocalizationService, LocalizationService>();

#if MACCATALYST
        builder.Services.AddSingleton<IPlatformService, Platforms.MacCatalyst.MacPlatformService>();
#else
        builder.Services.AddSingleton<IPlatformService, Services.DefaultPlatformService>();
#endif
        builder.Services.AddSingleton<FolderSync.Security.Services.IAnomalyDetectionService, FolderSync.Security.Services.AnomalyDetectionService>();

        builder.Services.AddSingleton<ISyncCoordinator>(sp => 
        {
            var peerService = sp.GetRequiredService<IPeerService>();
            var dbFactory = sp.GetRequiredService<IDbContextFactory<FolderSyncDbContext>>();
            var syncEngine = sp.GetRequiredService<ISyncEngine>();
            var fileTransfer = sp.GetRequiredService<IFileTransferService>();
            var conflict = sp.GetRequiredService<IConflictService>();
            var nat = sp.GetRequiredService<INatService>();
            var notify = sp.GetRequiredService<INotificationService>();
            var hash = sp.GetRequiredService<IHashService>();
            var cleanup = sp.GetRequiredService<ICleanupService>();
            var diskMonitor = sp.GetRequiredService<IDiskMonitorService>();
            var syncQueue = sp.GetRequiredService<ISyncQueue>();
            var anomalyService = sp.GetRequiredService<FolderSync.Security.Services.IAnomalyDetectionService>();
            return new SyncCoordinator(peerService, dbFactory, syncEngine, fileTransfer, conflict, nat, notify, hash, cleanup, diskMonitor, syncQueue, anomalyService, deviceId);
        });

        // 5. UI Layer
        builder.Services.AddSingleton<MainViewModel>();
        builder.Services.AddSingleton<MainPage>();
        
        builder.Services.AddTransient<SettingsViewModel>();
        builder.Services.AddTransient<SettingsPage>();

        builder.Services.AddTransient<HistoryViewModel>();
        builder.Services.AddTransient<HistoryPage>();

        builder.Services.AddTransient<ConflictsViewModel>();
        builder.Services.AddTransient<ConflictsPage>();

        builder.Services.AddTransient<PeersViewModel>();
        builder.Services.AddTransient<PeersPage>();

        builder.Services.AddTransient<VersionsViewModel>();
        builder.Services.AddTransient<VersionsPage>();

        builder.Services.AddSingleton<FolderSync.Core.Interfaces.IAuthenticationService, AuthenticationService>();

        builder.Services.AddTransient<VersionDiffViewModel>();
        builder.Services.AddTransient<VersionDiffPage>();

#if DEBUG
		builder.Logging.AddDebug();
#endif

		return builder.Build();
	}
}
