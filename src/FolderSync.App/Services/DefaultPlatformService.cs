using FolderSync.Core.Interfaces;

namespace FolderSync.App.Services;

public class DefaultPlatformService : IPlatformService
{
    public void SetAutoStart(bool enable) { }
    public bool IsAutoStartEnabled() => false;
    public void MinimizeToTray() { }
    public void Quit() => Environment.Exit(0);
}
