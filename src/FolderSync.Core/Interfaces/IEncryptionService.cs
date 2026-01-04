namespace FolderSync.Core.Interfaces;

public interface IEncryptionService
{
    /// <summary>
    /// Encrypts plain text using AES-256.
    /// </summary>
    string Encrypt(string plainText, string key);

    /// <summary>
    /// Decrypts cipher text using AES-256.
    /// </summary>
    string Decrypt(string cipherText, string key);

    /// <summary>
    /// Encrypts a file using AES-256.
    /// </summary>
    Task EncryptFileAsync(string inputFilePath, string outputFilePath, string key);

    /// <summary>
    /// Decrypts a file using AES-256.
    /// </summary>
    Task DecryptFileAsync(string inputFilePath, string outputFilePath, string key);

    Stream GetEncryptionStream(Stream baseStream, string password);
    Task<Stream> GetDecryptionStreamAsync(Stream baseStream, string password);
}
