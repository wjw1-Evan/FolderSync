using FolderSync.App.ViewModels;

namespace FolderSync.App;

public partial class HistoryPage : ContentPage
{
	private readonly HistoryViewModel _viewModel;

	public HistoryPage(HistoryViewModel viewModel)
	{
		InitializeComponent();
		BindingContext = _viewModel = viewModel;
	}

    protected override async void OnAppearing()
    {
        base.OnAppearing();
        await _viewModel.LoadHistoryAsync();
    }
}
