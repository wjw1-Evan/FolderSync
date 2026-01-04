namespace FolderSync.Core.Interfaces;

public interface INatService
{
    Task MapPortAsync(int port, string description);
    Task UnmapPortAsync(int port);
    Task<string?> GetExternalIpAsync();
}
