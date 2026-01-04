namespace FolderSync.Core.Models.Messages;

public class FileTransferMetadata
{
    public string RelativePath { get; set; } = string.Empty;
    public string Hash { get; set; } = string.Empty;
    public long Size { get; set; }
    public long Offset { get; set; }
    public bool IsResuming { get; set; }
    public bool IsQuickSend { get; set; }
    public bool UseCompression { get; set; }
    public string DeviceId { get; set; } = string.Empty;
}
