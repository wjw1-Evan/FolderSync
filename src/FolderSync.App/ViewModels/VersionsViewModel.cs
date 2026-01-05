using System.Collections.ObjectModel;
using System.Windows.Input;
using FolderSync.Data;
using FolderSync.Data.Entities;
using FolderSync.Sync.Services;
using Microsoft.EntityFrameworkCore;
using FolderSync.App.Services;

namespace FolderSync.App.ViewModels;

public class VersionsViewModel : BaseViewModel
{
    private readonly IDbContextFactory<FolderSyncDbContext> _dbFactory;
    private readonly IVersionManager _versionManager;
    private readonly ILocalizationService _localizationService;
    private ObservableCollection<FileVersionDisplay> _versions = new();
    private bool _isRefreshing;

    public VersionsViewModel(
        IDbContextFactory<FolderSyncDbContext> dbFactory,
        IVersionManager versionManager,
        ILocalizationService localizationService)
    {
        _dbFactory = dbFactory;
        _versionManager = versionManager;
        _localizationService = localizationService;
        Title = _localizationService["Versions"];

        LoadVersionsCommand = new Command(async () => await LoadVersionsAsync());
        UpdateNoteCommand = new Command<FileVersionDisplay>(async (v) => await UpdateNoteAsync(v));
    }

    public ObservableCollection<FileVersionDisplay> Versions
    {
        get => _versions;
        set => SetProperty(ref _versions, value);
    }

    public bool IsRefreshing
    {
        get => _isRefreshing;
        set => SetProperty(ref _isRefreshing, value);
    }

    public ICommand LoadVersionsCommand { get; }
    public ICommand UpdateNoteCommand { get; }

    public async Task LoadVersionsAsync()
    {
        IsRefreshing = true;
        try
        {
            using var db = await _dbFactory.CreateDbContextAsync();
            var versions = await db.FileVersions
                .Include(v => v.FileMetadata)
                .OrderByDescending(v => v.CreatedAt)
                .ToListAsync();

            var displayList = versions.Select(v => new FileVersionDisplay
            {
                Id = v.Id,
                FileName = Path.GetFileName(v.FilePath),
                FullPath = v.FilePath,
                CreatedAt = v.CreatedAt,
                Size = v.FileSize,
                Note = v.Note,
                VersionNumber = v.VersionNumber
            }).ToList();

            Versions = new ObservableCollection<FileVersionDisplay>(displayList);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error loading versions: {ex.Message}");
        }
        finally
        {
            IsRefreshing = false;
        }
    }

    private async Task UpdateNoteAsync(FileVersionDisplay vm)
    {
        if (vm == null) return;

        var page = Application.Current?.Windows.FirstOrDefault()?.Page;
        if (page == null) return;

        var result = await page.DisplayPromptAsync(
            "Update Note", 
            $"Enter note for version {vm.VersionNumber}:", 
            initialValue: vm.Note);

        if (result != null)
        {
            await _versionManager.UpdateVersionNoteAsync(vm.Id, result);
            vm.Note = result; // Update local UI
        }
    }
}

public class FileVersionDisplay : BaseViewModel
{
    public int Id { get; set; }
    public string FileName { get; set; } = string.Empty;
    public string FullPath { get; set; } = string.Empty;
    public DateTime CreatedAt { get; set; }
    public long Size { get; set; }
    public int VersionNumber { get; set; }
    
    private string? _note;
    public string? Note
    {
        get => _note;
        set => SetProperty(ref _note, value);
    }
}
