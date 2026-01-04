using FolderSync.Sync.Models;

namespace FolderSync.Sync.Services;

public interface ISyncQueue
{
    void Enqueue(SyncTask task);
    SyncTask? Dequeue();
    int Count { get; }
    event EventHandler? TaskAdded;
}

public class SyncQueueService : ISyncQueue
{
    private readonly PriorityQueue<SyncTask, int> _queue = new();
    private readonly object _lock = new();

    public event EventHandler? TaskAdded;

    public void Enqueue(SyncTask task)
    {
        lock (_lock)
        {
            // Lower priority value = higher priority in .NET PriorityQueue
            // High (2) -> 0, Medium (1) -> 1, Low (0) -> 2
            int priorityValue = 2 - (int)task.Priority;
            _queue.Enqueue(task, priorityValue);
        }
        TaskAdded?.Invoke(this, EventArgs.Empty);
    }

    public SyncTask? Dequeue()
    {
        lock (_lock)
        {
            return _queue.Count > 0 ? _queue.Dequeue() : null;
        }
    }

    public int Count
    {
        get
        {
            lock (_lock) return _queue.Count;
        }
    }
}
