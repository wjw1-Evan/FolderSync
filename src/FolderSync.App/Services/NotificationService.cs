using FolderSync.Core.Interfaces;

namespace FolderSync.App.Services;

public class NotificationService : INotificationService
{
    public event EventHandler<(string Title, string Message)>? NotificationReceived;

    public void ShowNotification(string title, string message)
    {
        NotificationReceived?.Invoke(this, (title, message));
        
        // Also try to show a system-level alert if possible
        MainThread.BeginInvokeOnMainThread(async () =>
        {
            var page = Application.Current?.Windows.FirstOrDefault()?.Page;
            if (page != null)
            {
                await page.DisplayAlertAsync(title, message, "OK");
            }
        });
    }
}
