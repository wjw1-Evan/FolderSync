using System.Security.Cryptography;
using System.Text;
using FolderSync.Core.Interfaces;

namespace FolderSync.Security.Services;

public class EncryptionService : IEncryptionService
{
    private const int KeySize = 256;
    private const int Iterations = 10000;
    // Note: In a production app, the salt should be unique or stored securely.
    private static readonly byte[] Salt = "FolderSyncSystemSalt"u8.ToArray();

    public string Encrypt(string plainText, string password)
    {
        using Aes aes = Aes.Create();
        aes.KeySize = KeySize;
        
        byte[] key = DeriveKey(password);
        aes.Key = key;
        aes.GenerateIV();

        using MemoryStream msEncrypt = new();
        msEncrypt.Write(aes.IV, 0, aes.IV.Length);

        using (ICryptoTransform encryptor = aes.CreateEncryptor())
        using (CryptoStream csEncrypt = new(msEncrypt, encryptor, CryptoStreamMode.Write))
        using (StreamWriter swEncrypt = new(csEncrypt))
        {
            swEncrypt.Write(plainText);
        }

        return Convert.ToBase64String(msEncrypt.ToArray());
    }

    public string Decrypt(string cipherText, string password)
    {
        byte[] fullCipher = Convert.FromBase64String(cipherText);
        using Aes aes = Aes.Create();
        aes.KeySize = KeySize;

        byte[] key = DeriveKey(password);
        aes.Key = key;

        byte[] iv = new byte[aes.BlockSize / 8];
        Buffer.BlockCopy(fullCipher, 0, iv, 0, iv.Length);
        aes.IV = iv;

        using MemoryStream msDecrypt = new(fullCipher, iv.Length, fullCipher.Length - iv.Length);
        using ICryptoTransform decryptor = aes.CreateDecryptor();
        using CryptoStream csDecrypt = new(msDecrypt, decryptor, CryptoStreamMode.Read);
        using StreamReader srDecrypt = new(csDecrypt);

        return srDecrypt.ReadToEnd();
    }

    public async Task EncryptFileAsync(string inputFilePath, string outputFilePath, string password)
    {
        using Aes aes = Aes.Create();
        aes.KeySize = KeySize;
        aes.Key = DeriveKey(password);
        aes.GenerateIV();

        using FileStream fsIn = new(inputFilePath, FileMode.Open, FileAccess.Read);
        using FileStream fsOut = new(outputFilePath, FileMode.Create, FileAccess.Write);

        await fsOut.WriteAsync(aes.IV, 0, aes.IV.Length);

        using ICryptoTransform encryptor = aes.CreateEncryptor();
        using CryptoStream cs = new(fsOut, encryptor, CryptoStreamMode.Write);

        await fsIn.CopyToAsync(cs);
    }

    public async Task DecryptFileAsync(string inputFilePath, string outputFilePath, string password)
    {
        using Aes aes = Aes.Create();
        aes.KeySize = KeySize;
        aes.Key = DeriveKey(password);

        using FileStream fsIn = new(inputFilePath, FileMode.Open, FileAccess.Read);
        
        byte[] iv = new byte[aes.BlockSize / 8];
        await fsIn.ReadExactlyAsync(iv, 0, iv.Length);
        aes.IV = iv;

        using FileStream fsOut = new(outputFilePath, FileMode.Create, FileAccess.Write);
        using ICryptoTransform decryptor = aes.CreateDecryptor();
        using CryptoStream cs = new(fsIn, decryptor, CryptoStreamMode.Read);

        await cs.CopyToAsync(fsOut);
    }

    public Stream GetEncryptionStream(Stream baseStream, string password)
    {
        using Aes aes = Aes.Create();
        aes.KeySize = KeySize;
        aes.Key = DeriveKey(password);
        aes.GenerateIV();

        // Write IV to base stream
        baseStream.Write(aes.IV, 0, aes.IV.Length);

        var encryptor = aes.CreateEncryptor();
        return new CryptoStream(baseStream, encryptor, CryptoStreamMode.Write, leaveOpen: true);
    }

    public async Task<Stream> GetDecryptionStreamAsync(Stream baseStream, string password)
    {
        using Aes aes = Aes.Create();
        aes.KeySize = KeySize;
        aes.Key = DeriveKey(password);

        byte[] iv = new byte[aes.BlockSize / 8];
        await baseStream.ReadExactlyAsync(iv, 0, iv.Length);
        aes.IV = iv;

        var decryptor = aes.CreateDecryptor();
        return new CryptoStream(baseStream, decryptor, CryptoStreamMode.Read, leaveOpen: true);
    }

    private static byte[] DeriveKey(string password)
    {
        return Rfc2898DeriveBytes.Pbkdf2(password, Salt, Iterations, HashAlgorithmName.SHA256, KeySize / 8);
    }
}
