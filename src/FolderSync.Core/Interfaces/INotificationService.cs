namespace FolderSync.Core.Interfaces;

public interface INotificationService
{
    void ShowNotification(string title, string message);
    event EventHandler<(string Title, string Message)> NotificationReceived;
}
