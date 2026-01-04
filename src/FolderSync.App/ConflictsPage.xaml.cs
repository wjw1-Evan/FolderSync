using FolderSync.App.ViewModels;

namespace FolderSync.App;

public partial class ConflictsPage : ContentPage
{
	private readonly ConflictsViewModel _viewModel;

	public ConflictsPage(ConflictsViewModel viewModel)
	{
		InitializeComponent();
		BindingContext = _viewModel = viewModel;
	}

    protected override async void OnAppearing()
    {
        base.OnAppearing();
        await _viewModel.LoadConflictsAsync();
    }
}
