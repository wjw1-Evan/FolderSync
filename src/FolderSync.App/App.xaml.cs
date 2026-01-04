using Microsoft.Extensions.DependencyInjection;

namespace FolderSync.App;

public partial class App : Application
{
    public static Services.ILocalizationService? LocalizationService { get; private set; }

	public App(FolderSync.Data.IDatabaseService databaseService, FolderSync.Sync.Services.ISyncCoordinator syncCoordinator, Services.ILocalizationService localizationService)
	{
		InitializeComponent();
        LocalizationService = localizationService;

        Task.Run(async () =>
        {
            await databaseService.InitializeAsync();
            await syncCoordinator.StartAsync();
        });
	}

	protected override Window CreateWindow(IActivationState? activationState)
	{
		return new Window(new AppShell());
	}
}