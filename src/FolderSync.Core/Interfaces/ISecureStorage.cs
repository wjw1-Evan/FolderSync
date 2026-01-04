namespace FolderSync.Core.Interfaces;

public interface ISecureStorage
{
    Task SetAsync(string key, string value);
    Task<string?> GetAsync(string key);
    bool Remove(string key);
    void RemoveAll();
}
