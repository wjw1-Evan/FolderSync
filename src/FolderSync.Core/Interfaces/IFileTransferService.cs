using FolderSync.Core.Models.Messages;

namespace FolderSync.Core.Interfaces;

public interface IFileTransferService
{
    Task StartListenerAsync(int port);
    void StopListener();
    Task SendFileAsync(string filePath, string relativePath, string targetIp, int targetPort, string deviceId, long requestedOffset = 0, bool isQuickSend = false);
    Task<string> ReceiveFileAsync(string expectedHash, string tempPath);
    
    event EventHandler<TransferProgressEventArgs> TransferProgress;
    event EventHandler<FileReceivedEventArgs> FileReceived;
}

public class FileReceivedEventArgs : EventArgs
{
    public string TempPath { get; set; } = string.Empty;
    public FileTransferMetadata Metadata { get; set; } = new();
}

public class TransferProgressEventArgs : EventArgs
{
    public string FileName { get; set; } = string.Empty;
    public long BytesTransferred { get; set; }
    public long TotalBytes { get; set; }
}
