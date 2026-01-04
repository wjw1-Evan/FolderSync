using System.Security.Cryptography;
using System.Text;
using FolderSync.Core.Interfaces;

namespace FolderSync.Security.Services;

public class HashService : IHashService
{
    public string ComputeHash(string input)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(input);
        byte[] hash = SHA256.HashData(bytes);
        return ConvertToHexString(hash);
    }

    public async Task<string> ComputeFileHashAsync(string filePath)
    {
        using FileStream stream = File.OpenRead(filePath);
        return await ComputeHashAsync(stream);
    }

    public async Task<string> ComputeHashAsync(Stream stream)
    {
        byte[] hash = await SHA256.HashDataAsync(stream);
        return ConvertToHexString(hash);
    }

    private static string ConvertToHexString(byte[] bytes)
    {
        StringBuilder builder = new();
        foreach (byte b in bytes)
        {
            builder.Append(b.ToString("x2"));
        }
        return builder.ToString();
    }
}
