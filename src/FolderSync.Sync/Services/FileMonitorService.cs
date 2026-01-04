using FolderSync.Core.Interfaces;

namespace FolderSync.Sync.Services;

public interface IFileMonitorService
{
    void StartMonitoring(string path);
    void StopMonitoring(string path);
    event EventHandler<FileChangedEventArgs> FileChanged;
}

public class FileChangedEventArgs : EventArgs
{
    public string FullPath { get; set; } = string.Empty;
    public WatcherChangeTypes ChangeType { get; set; }
}

public class FileMonitorService : IFileMonitorService, IDisposable
{
    private readonly Dictionary<string, FileSystemWatcher> _watchers = new();
    private readonly TimeSpan _debounceTime = TimeSpan.FromSeconds(3);
    private readonly Dictionary<string, Timer> _debounceTimers = new();

    public event EventHandler<FileChangedEventArgs>? FileChanged;

    public void StartMonitoring(string path)
    {
        if (_watchers.ContainsKey(path)) return;

        var watcher = new FileSystemWatcher(path)
        {
            IncludeSubdirectories = true,
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size
        };

        watcher.Changed += OnFileSystemEvent;
        watcher.Created += OnFileSystemEvent;
        watcher.Deleted += OnFileSystemEvent;
        watcher.Renamed += OnFileSystemEvent;

        watcher.EnableRaisingEvents = true;
        _watchers[path] = watcher;
    }

    public void StopMonitoring(string path)
    {
        if (_watchers.TryGetValue(path, out var watcher))
        {
            watcher.EnableRaisingEvents = false;
            watcher.Dispose();
            _watchers.Remove(path);
        }
    }

    private void OnFileSystemEvent(object sender, FileSystemEventArgs e)
    {
        // Skip temporary files or hidden files if needed
        if (Path.GetFileName(e.FullPath).StartsWith(".") || e.FullPath.Contains(".DS_Store")) return;

        // Implement debouncing
        lock (_debounceTimers)
        {
            if (_debounceTimers.TryGetValue(e.FullPath, out var timer))
            {
                timer.Change(_debounceTime, Timeout.InfiniteTimeSpan);
            }
            else
            {
                _debounceTimers[e.FullPath] = new Timer(state =>
                {
                    var args = (FileChangedEventArgs)state!;
                    FileChanged?.Invoke(this, args);
                    lock (_debounceTimers)
                    {
                        _debounceTimers.Remove(args.FullPath);
                    }
                }, new FileChangedEventArgs { FullPath = e.FullPath, ChangeType = e.ChangeType }, _debounceTime, Timeout.InfiniteTimeSpan);
            }
        }
    }

    public void Dispose()
    {
        foreach (var watcher in _watchers.Values)
        {
            watcher.Dispose();
        }
        foreach (var timer in _debounceTimers.Values)
        {
            timer.Dispose();
        }
        _watchers.Clear();
        _debounceTimers.Clear();
    }
}
