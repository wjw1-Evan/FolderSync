using System.Text.Json;
using FolderSync.Core.Interfaces;
using FolderSync.Core.Models.Messages;
using NetMQ;
using NetMQ.Sockets;

namespace FolderSync.P2P.Services;

public class PeerService : IPeerService, IDisposable
{
    private readonly string _deviceId;
    private readonly string _deviceName;
    private readonly int _port;
    private readonly int _responsePort;
    
    private NetMQBeacon? _beacon;
    private NetMQPoller? _poller;
    private RouterSocket? _routerSocket;
    private bool _isDisposed;

    private readonly Dictionary<string, PeerDiscoveredEventArgs> _activePeers = new();

    public event EventHandler<PeerDiscoveredEventArgs>? PeerDiscovered;
    public event EventHandler<MessageReceivedEventArgs>? MessageReceived;

    public PeerService(string deviceId, string deviceName, int port = 5000)
    {
        _deviceId = deviceId;
        _deviceName = deviceName;
        _port = port;
        _responsePort = port + 1;
    }

    public Task StartAsync()
    {
        if (_beacon != null) return Task.CompletedTask;

        _beacon = new NetMQBeacon();
        _beacon.Configure(_port);
        _beacon.Publish($"{_deviceName}:{_deviceId}:{_responsePort}", TimeSpan.FromSeconds(1));
        
        _beacon.ReceiveReady += (s, e) =>
        {
            var beaconMessage = _beacon.Receive();
            if (beaconMessage.String == null) return;

            var parts = beaconMessage.String.Split(':');
            if (parts.Length < 3) return;

            var name = parts[0];
            var id = parts[1];
            if (!int.TryParse(parts[2], out int peerResponsePort)) return;

            if (id == _deviceId) return;

            var peerInfo = new PeerDiscoveredEventArgs
            {
                DeviceId = id,
                DeviceName = name,
                IpAddress = beaconMessage.PeerAddress,
                Port = peerResponsePort
            };

            lock (_activePeers)
            {
                if (!_activePeers.ContainsKey(id))
                {
                    _activePeers[id] = peerInfo;
                    PeerDiscovered?.Invoke(this, peerInfo);
                }
                else
                {
                    // Update IP/Port if changed
                    _activePeers[id] = peerInfo;
                }
            }
        };

        _routerSocket = new RouterSocket();
        _routerSocket.Bind($"tcp://0.0.0.0:{_responsePort}");

        _routerSocket.ReceiveReady += (s, e) =>
        {
            var clientAddress = _routerSocket.ReceiveFrameBytes();
            _routerSocket.ReceiveFrameBytes(); // Empty frame
            var messageJson = _routerSocket.ReceiveFrameString();

            MessageReceived?.Invoke(this, new MessageReceivedEventArgs
            {
                SenderIp = "", 
                MessageJson = messageJson
            });
        };

        _poller = new NetMQPoller { _beacon, _routerSocket };
        _poller.RunAsync();

        return Task.CompletedTask;
    }

    public async Task SendMessageAsync<T>(T message) where T : class
    {
        List<PeerDiscoveredEventArgs> targets;
        lock (_activePeers)
        {
            targets = _activePeers.Values.ToList();
        }

        foreach (var peer in targets)
        {
            await SendToPeerAsync(peer.IpAddress, peer.Port, message);
        }
    }

    public async Task SendToPeerAsync<T>(string ipAddress, int port, T message) where T : class
    {
        try
        {
            using var requestSocket = new RequestSocket();
            requestSocket.Connect($"tcp://{ipAddress}:{port}");
            
            var json = JsonSerializer.Serialize(message);
            requestSocket.SendFrame(json);
            
            // Wait for brief ACK to ensure delivery
            bool received = requestSocket.TryReceiveFrameString(TimeSpan.FromSeconds(2), out _);
            if (!received)
            {
                Console.WriteLine($"Failed to get ACK from {ipAddress}:{port}");
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error sending message to {ipAddress}:{port}: {ex.Message}");
        }
    }

    public Task StopAsync()
    {
        _poller?.Stop();
        _beacon?.Dispose();
        _routerSocket?.Dispose();
        _beacon = null;
        _routerSocket = null;
        return Task.CompletedTask;
    }

    public Task BroadcastPresenceAsync() => Task.CompletedTask;

    public Task ConnectToPeerAsync(string ipAddress, int port) => Task.CompletedTask;

    public bool IsPeerOnline(string deviceId)
    {
        lock (_activePeers)
        {
            return _activePeers.ContainsKey(deviceId);
        }
    }

    public void Dispose()
    {
        if (_isDisposed) return;
        StopAsync().Wait();
        _poller?.Dispose();
        _isDisposed = true;
        GC.SuppressFinalize(this);
    }
}
