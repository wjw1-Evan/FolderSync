using Open.Nat;
using FolderSync.Core.Interfaces;

namespace FolderSync.P2P.Services;

public class NatService : INatService
{
    private NatDevice? _device;

    private async Task<NatDevice?> GetDeviceAsync()
    {
        if (_device != null) return _device;

        try
        {
            var discoverer = new NatDiscoverer();
            var cts = new CancellationTokenSource(5000);
            _device = await discoverer.DiscoverDeviceAsync(PortMapper.Upnp, cts);
            return _device;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"NAT Discovery failed: {ex.Message}");
            return null;
        }
    }

    public async Task MapPortAsync(int port, string description)
    {
        var device = await GetDeviceAsync();
        if (device == null) return;

        try
        {
            await device.CreatePortMapAsync(new Mapping(Protocol.Tcp, port, port, description));
            Console.WriteLine($"Successfully mapped port {port} via UPnP");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to map port {port}: {ex.Message}");
        }
    }

    public async Task UnmapPortAsync(int port)
    {
        var device = await GetDeviceAsync();
        if (device == null) return;

        try
        {
            await device.DeletePortMapAsync(new Mapping(Protocol.Tcp, port, port));
            Console.WriteLine($"Successfully unmapped port {port}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to unmap port {port}: {ex.Message}");
        }
    }

    public async Task<string?> GetExternalIpAsync()
    {
        var device = await GetDeviceAsync();
        if (device == null) return null;

        try
        {
            var ip = await device.GetExternalIPAsync();
            return ip.ToString();
        }
        catch
        {
            return null;
        }
    }
}
