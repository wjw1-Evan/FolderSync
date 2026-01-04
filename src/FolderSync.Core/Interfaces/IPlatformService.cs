namespace FolderSync.Core.Interfaces;

public interface IPlatformService
{
    void SetAutoStart(bool enable);
    bool IsAutoStartEnabled();
    void MinimizeToTray();
    void Quit();
}
