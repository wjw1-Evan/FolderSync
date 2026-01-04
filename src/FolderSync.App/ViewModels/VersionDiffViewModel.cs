using System.Collections.ObjectModel;
using FolderSync.Sync.Services;

namespace FolderSync.App.ViewModels;

public class VersionDiffViewModel : BaseViewModel
{
    private readonly IDiffService _diffService;
    private ObservableCollection<DiffLine> _diffLines = new();

    public VersionDiffViewModel(IDiffService diffService)
    {
        _diffService = diffService;
        Title = "Version Comparison";
    }

    public ObservableCollection<DiffLine> DiffLines
    {
        get => _diffLines;
        set => SetProperty(ref _diffLines, value);
    }

    public void LoadDiff(string oldText, string newText)
    {
        var result = _diffService.Compare(oldText, newText);
        DiffLines = new ObservableCollection<DiffLine>(result.Lines);
    }
}
