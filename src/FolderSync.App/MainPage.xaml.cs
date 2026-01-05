using FolderSync.App.ViewModels;

namespace FolderSync.App;

public partial class MainPage : ContentPage
{
	private readonly MainViewModel _viewModel;

	public MainPage(MainViewModel viewModel)
	{
		InitializeComponent();
		_viewModel = viewModel;
		BindingContext = _viewModel;
	}

    protected override async void OnAppearing()
    {
        base.OnAppearing();
        await _viewModel.InitializeAsync();
    }

    private async void OnAddFolderClicked(object sender, EventArgs e)
    {
        // For demo purposes, we can use a hardcoded path or ask the user
        // In a real app, use FolderPicker if on supported platform
        var result = await DisplayActionSheetAsync("Select Type", "Cancel", null, "Pictures", "Documents", "Downloads");
        
        if (result != "Cancel")
        {
            string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), result);
            if (!Directory.Exists(path)) Directory.CreateDirectory(path);
            
            await _viewModel.AddFolderAsync(path);
        }
    }
}
