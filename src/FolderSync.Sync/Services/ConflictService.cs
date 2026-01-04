using FolderSync.Data.Entities;

namespace FolderSync.Sync.Services;

public interface IConflictService
{
    string GetConflictPath(string localPath, string deviceName = "Conflict");
}

public class ConflictService : IConflictService
{
    public string GetConflictPath(string localPath, string deviceName = "Conflict")
    {
        string directory = Path.GetDirectoryName(localPath) ?? "";
        string fileName = Path.GetFileNameWithoutExtension(localPath);
        string extension = Path.GetExtension(localPath);
        string timestamp = DateTime.Now.ToString("yyyyMMddHHmmss");
        
        string newName = $"{fileName}_{deviceName}_{timestamp}{extension}";
        return Path.Combine(directory, newName);
    }
}
