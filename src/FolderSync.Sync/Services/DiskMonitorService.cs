namespace FolderSync.Sync.Services;

public interface IDiskMonitorService
{
    Task CheckDiskSpaceAsync();
    event EventHandler<long> LowDiskSpaceDetected;
}

public class DiskMonitorService : IDiskMonitorService
{
    public event EventHandler<long>? LowDiskSpaceDetected;
    private const long LowSpaceThreshold = 1024L * 1024 * 1024; // 1GB

    public Task CheckDiskSpaceAsync()
    {
        try
        {
            var drives = DriveInfo.GetDrives();
            foreach (var drive in drives.Where(d => d.IsReady))
            {
                if (drive.AvailableFreeSpace < LowSpaceThreshold)
                {
                    LowDiskSpaceDetected?.Invoke(this, drive.AvailableFreeSpace);
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error monitoring disk space: {ex.Message}");
        }
        return Task.CompletedTask;
    }
}
