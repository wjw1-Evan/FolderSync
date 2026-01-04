namespace FolderSync.Core.Interfaces;

public interface IHashService
{
    /// <summary>
    /// Computes the SHA256 hash of a string.
    /// </summary>
    string ComputeHash(string input);

    /// <summary>
    /// Computes the SHA256 hash of a file.
    /// </summary>
    Task<string> ComputeFileHashAsync(string filePath);

    /// <summary>
    /// Computes the SHA256 hash of a stream.
    /// </summary>
    Task<string> ComputeHashAsync(Stream stream);
}
