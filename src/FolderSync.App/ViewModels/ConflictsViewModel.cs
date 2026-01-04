using System.Collections.ObjectModel;
using System.Windows.Input;
using FolderSync.Data;
using FolderSync.Data.Entities;
using Microsoft.EntityFrameworkCore;

namespace FolderSync.App.ViewModels;

public class ConflictsViewModel : BaseViewModel
{
    private readonly IDbContextFactory<FolderSyncDbContext> _dbFactory;
    private ObservableCollection<SyncConflict> _conflicts = new();

    public ConflictsViewModel(IDbContextFactory<FolderSyncDbContext> dbFactory)
    {
        _dbFactory = dbFactory;
        Title = "Conflicts";
        LoadConflictsCommand = new Command(async () => await LoadConflictsAsync());
        ResolveConflictCommand = new Command<SyncConflict>(async (c) => await ResolveConflictAsync(c));
    }

    public ObservableCollection<SyncConflict> Conflicts
    {
        get => _conflicts;
        set => SetProperty(ref _conflicts, value);
    }

    public ICommand LoadConflictsCommand { get; }
    public ICommand ResolveConflictCommand { get; }

    public async Task LoadConflictsAsync()
    {
        IsBusy = true;
        try
        {
            using var db = await _dbFactory.CreateDbContextAsync();
            var list = await db.SyncConflicts
                .OrderByDescending(c => c.ConflictTime)
                .ToListAsync();
            Conflicts = new ObservableCollection<SyncConflict>(list);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error loading conflicts: {ex.Message}");
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task ResolveConflictAsync(SyncConflict conflict)
    {
        // Simple resolution for now: mark as resolved.
        // In a real app, you might delete one version or merge.
        try
        {
            using var db = await _dbFactory.CreateDbContextAsync();
            conflict.Resolution = ConflictResolution.Ignored; // Or handled manually
            db.SyncConflicts.Update(conflict);
            await db.SaveChangesAsync();
            await LoadConflictsAsync();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error resolving conflict: {ex.Message}");
        }
    }
}
