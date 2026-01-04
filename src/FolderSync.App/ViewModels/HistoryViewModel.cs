using System.Collections.ObjectModel;
using System.Windows.Input;
using FolderSync.Data;
using FolderSync.Data.Entities;
using Microsoft.EntityFrameworkCore;

namespace FolderSync.App.ViewModels;

public class HistoryViewModel : BaseViewModel
{
    private readonly IDbContextFactory<FolderSyncDbContext> _dbFactory;
    private ObservableCollection<SyncHistory> _historyRecords = new();

    public HistoryViewModel(IDbContextFactory<FolderSyncDbContext> dbFactory)
    {
        _dbFactory = dbFactory;
        Title = "Sync History";
        LoadHistoryCommand = new Command(async () => await LoadHistoryAsync());
    }

    public ObservableCollection<SyncHistory> HistoryRecords
    {
        get => _historyRecords;
        set => SetProperty(ref _historyRecords, value);
    }

    public ICommand LoadHistoryCommand { get; }

    public async Task LoadHistoryAsync()
    {
        IsBusy = true;
        try
        {
            using var db = await _dbFactory.CreateDbContextAsync();
            
            // Fetch last 100 records
            var records = await db.SyncHistories
                .OrderByDescending(h => h.Timestamp)
                .Take(100)
                .ToListAsync();

            HistoryRecords = new ObservableCollection<SyncHistory>(records);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error loading history: {ex.Message}");
        }
        finally
        {
            IsBusy = false;
        }
    }
}
