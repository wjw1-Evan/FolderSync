using FolderSync.Core.Interfaces;
using Microsoft.Maui.Storage;

namespace FolderSync.App.Services;

public class MauiSecureStorage : FolderSync.Core.Interfaces.ISecureStorage
{
    public async Task SetAsync(string key, string value)
    {
        await SecureStorage.Default.SetAsync(key, value);
    }

    public async Task<string?> GetAsync(string key)
    {
        return await SecureStorage.Default.GetAsync(key);
    }

    public bool Remove(string key)
    {
        return SecureStorage.Default.Remove(key);
    }

    public void RemoveAll()
    {
        SecureStorage.Default.RemoveAll();
    }
}
