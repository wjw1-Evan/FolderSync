namespace FolderSync.Security.Services;

public interface IAnomalyDetectionService
{
    /// <summary>
    /// Records an event to check for anomalies.
    /// </summary>
    /// <param name="eventType">Type of event (e.g., "FileDeletion", "AuthFailure")</param>
    /// <param name="details">Optional details</param>
    Task RecordEventAsync(string eventType, string userOrDeviceId, string details = "");

    event EventHandler<AnomalyDetectedEventArgs>? AnomalyDetected;
}

public class AnomalyDetectedEventArgs : EventArgs
{
    public string EventType { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public string Severity { get; set; } = "DateWarning";
}
