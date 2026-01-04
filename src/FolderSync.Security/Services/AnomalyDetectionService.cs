using System.Collections.Concurrent;

namespace FolderSync.Security.Services;

public class AnomalyDetectionService : IAnomalyDetectionService
{
    // Thresholds
    private const int MaxDeletionsPerMinute = 10;
    private const int MaxAuthFailuresPerMinute = 5;
    
    // Tracking [EventType_Key -> TimeQueue]
    private readonly ConcurrentDictionary<string, ConcurrentQueue<DateTime>> _eventTracker = new();

    public event EventHandler<AnomalyDetectedEventArgs>? AnomalyDetected;

    public Task RecordEventAsync(string eventType, string key, string details = "")
    {
        string trackKey = $"{eventType}_{key}";
        
        var queue = _eventTracker.GetOrAdd(trackKey, _ => new ConcurrentQueue<DateTime>());
        queue.Enqueue(DateTime.UtcNow);

        CleanupOldEvents(queue);

        if (CheckThreshold(eventType, queue.Count))
        {
            OnAnomalyDetected(eventType, key, details);
            // Clear queue to avoid spamming alerts for the same burst
            queue.Clear();
        }

        return Task.CompletedTask;
    }

    private void CleanupOldEvents(ConcurrentQueue<DateTime> queue)
    {
        DateTime cutoff = DateTime.UtcNow.AddMinutes(-1);
        while (queue.TryPeek(out var time) && time < cutoff)
        {
            queue.TryDequeue(out _);
        }
    }

    private bool CheckThreshold(string eventType, int count)
    {
        if (eventType == "FileDelete") return count >= MaxDeletionsPerMinute;
        if (eventType == "AuthFail") return count >= MaxAuthFailuresPerMinute;
        return false;
    }

    protected virtual void OnAnomalyDetected(string eventType, string key, string details)
    {
        string message = "";
        string severity = "Warning";

        if (eventType == "FileDelete")
        {
            message = $"High volume of deletions detected from {key}. ({details})";
            severity = "High";
        }
        else if (eventType == "AuthFail")
        {
            message = $"Multiple authentication failures detected for {key}.";
            severity = "Medium";
        }

        AnomalyDetected?.Invoke(this, new AnomalyDetectedEventArgs
        {
            EventType = eventType,
            Description = message,
            Severity = severity
        });
    }
}
