using FolderSync.Security.Services;
using System.Text;
using Xunit;

namespace FolderSync.Tests;

public class SecurityTests
{
    private readonly EncryptionService _encryption;
    private readonly HashService _hash;

    public SecurityTests()
    {
        _encryption = new EncryptionService();
        _hash = new HashService();
    }

    [Fact]
    public void Encryption_Roundtrip_Works()
    {
        string original = "Hello FolderSync!";
        string password = "strong-password";

        string encrypted = _encryption.Encrypt(original, password);
        string decrypted = _encryption.Decrypt(encrypted, password);

        Assert.Equal(original, decrypted);
        Assert.NotEqual(original, encrypted);
    }

    [Fact]
    public async Task Hash_Consistency_Works()
    {
        string content = "shared content";
        string path = Path.GetTempFileName();
        File.WriteAllText(path, content);

        try
        {
            string hash1 = await _hash.ComputeFileHashAsync(path);
            string hash2 = await _hash.ComputeFileHashAsync(path);

            Assert.Equal(hash1, hash2);
            Assert.NotEmpty(hash1);
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
        }
    }
}
