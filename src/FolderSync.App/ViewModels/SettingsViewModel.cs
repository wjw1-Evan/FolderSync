using System.Collections.ObjectModel;
using System.Text.Json;
using System.Windows.Input;
using FolderSync.Core.Interfaces;
using FolderSync.Core.Models;
using FolderSync.Data;
using FolderSync.Data.Entities;
using System.Globalization;
using FolderSync.App.Services;
using Microsoft.EntityFrameworkCore;

namespace FolderSync.App.ViewModels;

public class SettingsViewModel : BaseViewModel
{
    private readonly IDbContextFactory<FolderSyncDbContext> _dbFactory;
    private readonly IPeerService _peerService;
    private readonly ILocalizationService _localizationService;
    private readonly IAuthenticationService _authService;
    private readonly IPlatformService _platformService;
    private ObservableCollection<SyncConfiguration> _syncConfigs = new();
    private string _deviceName = string.Empty;
    private string _deviceId = string.Empty;
    private string _selectedLanguage = "English";
    private bool _isAppLockEnabled;
    private bool _isLaunchOnStartupEnabled;

    public SettingsViewModel(
        IDbContextFactory<FolderSyncDbContext> dbFactory,
        IPeerService peerService,
        ILocalizationService localizationService,
        IAuthenticationService authService,
        IPlatformService platformService)
    {
        _dbFactory = dbFactory;
        _peerService = peerService;
        _localizationService = localizationService;
        _authService = authService;
        _platformService = platformService;
        
        Title = _localizationService["Settings"];
        LoadSettingsCommand = new Command(async () => await LoadSettingsAsync());
        SaveConfigCommand = new Command<SyncConfiguration>(async (config) => await SaveConfigAsync(config));
        ManageAppLockCommand = new Command(async () => await ManageAppLockAsync());
    }

    public ObservableCollection<SyncConfiguration> SyncConfigs
    {
        get => _syncConfigs;
        set => SetProperty(ref _syncConfigs, value);
    }

    public string DeviceName
    {
        get => _deviceName;
        set => SetProperty(ref _deviceName, value);
    }

    public string DeviceId
    {
        get => _deviceId;
        set => SetProperty(ref _deviceId, value);
    }

    public List<string> Languages { get; } = new() { "English", "简体中文" };

    public string SelectedLanguage
    {
        get => _selectedLanguage;
        set
        {
            if (SetProperty(ref _selectedLanguage, value))
            {
                var culture = value == "简体中文" ? new CultureInfo("zh-Hans") : new CultureInfo("en-US");
                _localizationService.CurrentCulture = culture;
                Title = _localizationService["Settings"];
            }
        }
    }

    public bool IsAppLockEnabled
    {
        get => _isAppLockEnabled;
        set => SetProperty(ref _isAppLockEnabled, value);
    }

    public bool IsLaunchOnStartupEnabled
    {
        get => _isLaunchOnStartupEnabled;
        set
        {
            if (SetProperty(ref _isLaunchOnStartupEnabled, value))
            {
                _platformService.SetAutoStart(value);
            }
        }
    }

    public ICommand LoadSettingsCommand { get; }
    public ICommand SaveConfigCommand { get; }
    public ICommand ManageAppLockCommand { get; }

    public async Task LoadSettingsAsync()
    {
        IsBusy = true;
        try
        {
            // Load Device Info (In a real app, these might come from a dedicated settings service)
            // For now, we grab what we can from PeerService or similar if exposed, 
            // but we didn't expose them in IPeerService properties. 
            // We'll placeholder them or fetch from DB if we stored ClientIdentity there.
            
            using var db = await _dbFactory.CreateDbContextAsync();
            var identity = await db.ClientIdentities.FirstOrDefaultAsync();
            if (identity != null)
            {
                DeviceName = identity.DeviceName;
                DeviceId = identity.ClientId;
            }
            else
            {
                 DeviceName = "Unknown (Not Initialized)";
                 DeviceId = "N/A";
            }

            var configs = await db.SyncConfigurations.ToListAsync();
            SyncConfigs = new ObservableCollection<SyncConfiguration>(configs);

            // Load Auth Status
            IsAppLockEnabled = await _authService.IsAuthenticationEnabledAsync();

            // Load AutoStart status
            IsLaunchOnStartupEnabled = _platformService.IsAutoStartEnabled();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error loading settings: {ex.Message}");
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task SaveConfigAsync(SyncConfiguration config)
    {
        if (config == null) return;
        
        // Validate JSON
        try
        {
            if (!string.IsNullOrWhiteSpace(config.FilterRules))
            {
                // Try parse to ensure valid JSON
                JsonSerializer.Deserialize<SyncFilter>(config.FilterRules);
            }
            
            using var db = await _dbFactory.CreateDbContextAsync();
            db.SyncConfigurations.Update(config);
            await db.SaveChangesAsync();
            
            // In a real app, we might need to notify SyncEngine to reload config or restart monitoring
        }
        catch (JsonException)
        {
            // Show error (would need a dialog service)
            Console.WriteLine("Invalid JSON Format for filters");
        }
        catch (Exception ex)
        {
             Console.WriteLine($"Error saving config: {ex.Message}");
        }
    }

    private async Task ManageAppLockAsync()
    {
        bool isCurrentlyEnabled = await _authService.IsAuthenticationEnabledAsync();

        if (isCurrentlyEnabled)
        {
            // Remove Lock Flow
            string pin = await Application.Current.MainPage.DisplayPromptAsync("Remove App Lock", "Enter current PIN to remove lock:");
            if (string.IsNullOrEmpty(pin)) return;

            if (await _authService.VerifyPinAsync(pin))
            {
                await _authService.RemovePinAsync();
                IsAppLockEnabled = false;
                await Application.Current.MainPage.DisplayAlert("Success", "App Lock removed.", "OK");
            }
            else
            {
                await Application.Current.MainPage.DisplayAlert("Error", "Incorrect PIN.", "OK");
            }
        }
        else
        {
            // Set Lock Flow
            string pin = await Application.Current.MainPage.DisplayPromptAsync("Set App Lock", "Enter new PIN (4-6 digits):", maxLength: 6, keyboard: Keyboard.Numeric);
            if (string.IsNullOrEmpty(pin) || pin.Length < 4)
            {
                if (pin != null) await Application.Current.MainPage.DisplayAlert("Error", "PIN too short.", "OK");
                return;
            }

            await _authService.SetPinAsync(pin);
            IsAppLockEnabled = true;
            await Application.Current.MainPage.DisplayAlert("Success", "App Lock enabled.", "OK");
        }
    }
}
