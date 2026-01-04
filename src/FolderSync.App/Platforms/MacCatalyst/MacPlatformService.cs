using FolderSync.Core.Interfaces;
using Foundation;
using UIKit;

namespace FolderSync.App.Platforms.MacCatalyst;

public class MacPlatformService : IPlatformService
{
    public void SetAutoStart(bool enable)
    {
        // On Mac, we'd traditionally use a LaunchAgent plist.
        // For now, let's implement a simplified version or log the intent.
        Console.WriteLine($"AutoStart set to: {enable}");
        
        string plistPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Personal), 
            "Library/LaunchAgents/com.foldersync.app.plist");

        if (enable)
        {
            string execPath = NSBundle.MainBundle.BundlePath;
            string plistContent = $@"<?xml version=""1.0"" encoding=""UTF-8""?>
<!DOCTYPE plist PUBLIC ""-//Apple//DTD PLIST 1.0//EN"" ""http://www.apple.com/DTDs/PropertyList-1.0.dtd"">
<plist version=""1.0"">
<dict>
    <key>Label</key>
    <string>com.foldersync.app</string>
    <key>ProgramArguments</key>
    <array>
        <string>{execPath}/Contents/MacOS/FolderSync.App</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>";
            try { File.WriteAllText(plistPath, plistContent); } catch { }
        }
        else
        {
            if (File.Exists(plistPath)) File.Delete(plistPath);
        }
    }

    public bool IsAutoStartEnabled()
    {
        string plistPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Personal), 
            "Library/LaunchAgents/com.foldersync.app.plist");
        return File.Exists(plistPath);
    }

    public void MinimizeToTray()
    {
        // In MAUI, we can use the Window property if available
        var window = Application.Current?.Windows.FirstOrDefault()?.Handler?.PlatformView as UIWindow;
        if (window != null)
        {
            window.Hidden = true;
        }
    }

    public void Quit()
    {
        Application.Current?.Quit();
    }
}
