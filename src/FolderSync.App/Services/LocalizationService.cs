using System.Globalization;
using System.ComponentModel;
using System.Resources;

namespace FolderSync.App.Services;

public interface ILocalizationService : INotifyPropertyChanged
{
    CultureInfo CurrentCulture { get; set; }
    string this[string key] { get; }
}

public class LocalizationService : ILocalizationService
{
    public event PropertyChangedEventHandler? PropertyChanged;
    private readonly ResourceManager _resourceManager;
    private CultureInfo _currentCulture;

    public LocalizationService()
    {
        _resourceManager = new ResourceManager("FolderSync.Core.Resources.AppResources", typeof(FolderSync.Core.Models.Messages.BaseMessage).Assembly);
        _currentCulture = CultureInfo.CurrentUICulture;
    }

    public CultureInfo CurrentCulture
    {
        get => _currentCulture;
        set
        {
            if (_currentCulture != value)
            {
                _currentCulture = value;
                CultureInfo.DefaultThreadCurrentCulture = value;
                CultureInfo.DefaultThreadCurrentUICulture = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null)); // Notify all
            }
        }
    }

    public string this[string key] => _resourceManager.GetString(key, _currentCulture) ?? key;
}
