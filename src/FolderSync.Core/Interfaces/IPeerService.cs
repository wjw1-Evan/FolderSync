namespace FolderSync.Core.Interfaces;

public enum PeerConnectionStatus
{
    Disconnected,
    Connecting,
    Connected,
    Refused,
    Error
}

public interface IPeerService
{
    Task StartAsync();
    Task StopAsync();
    
    /// <summary>
    /// Broadcasts presence to the LAN.
    /// </summary>
    Task BroadcastPresenceAsync();

    /// <summary>
    /// Connects to a specific peer by address and port.
    /// </summary>
    Task ConnectToPeerAsync(string ipAddress, int port);

    /// <summary>
    /// Sends a message to all connected peers or a specific one.
    /// </summary>
    Task SendMessageAsync<T>(T message) where T : class;
    Task SendToPeerAsync<T>(string ipAddress, int port, T message) where T : class;

    /// <summary>
    /// Event triggered when a new peer is discovered.
    /// </summary>
    event EventHandler<PeerDiscoveredEventArgs> PeerDiscovered;

    /// <summary>
    /// Event triggered when a message is received from a peer.
    /// </summary>
    event EventHandler<MessageReceivedEventArgs> MessageReceived;
    
    bool IsPeerOnline(string deviceId);
}

public class MessageReceivedEventArgs : EventArgs
{
    public string SenderIp { get; set; } = string.Empty;
    public string SenderDeviceId { get; set; } = string.Empty;
    public string MessageJson { get; set; } = string.Empty;
}

public class PeerDiscoveredEventArgs : EventArgs
{
    public string DeviceId { get; set; } = string.Empty;
    public string DeviceName { get; set; } = string.Empty;
    public string IpAddress { get; set; } = string.Empty;
    public int Port { get; set; }
}
