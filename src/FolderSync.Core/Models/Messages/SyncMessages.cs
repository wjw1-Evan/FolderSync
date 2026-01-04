namespace FolderSync.Core.Models.Messages;

public enum MessageType
{
    Handshake,
    SyncMeta,
    FileRequest,
    FileChunk,
    FileComplete,
    QuickSend,
    PairingRequest,
    PairingResponse,
    Error
}

public class BaseMessage
{
    public MessageType Type { get; set; }
    public string SenderDeviceId { get; set; } = string.Empty;
    public DateTime Timestamp { get; set; } = DateTime.UtcNow;
}

public class HandshakeMessage : BaseMessage
{
    public HandshakeMessage() => Type = MessageType.Handshake;
    public string DeviceName { get; set; } = string.Empty;
}

public class SyncMetaMessage : BaseMessage
{
    public SyncMetaMessage() => Type = MessageType.SyncMeta;
    public List<FileDelta> Deltas { get; set; } = new();
}

public class FileDelta
{
    public string FilePath { get; set; } = string.Empty;
    public string Hash { get; set; } = string.Empty;
    public long Size { get; set; }
    public bool IsDeleted { get; set; }
}

public class FileRequestMessage : BaseMessage
{
    public FileRequestMessage() => Type = MessageType.FileRequest;
    public string FilePath { get; set; } = string.Empty;
    public string ExpectedHash { get; set; } = string.Empty;
    public long RequestedOffset { get; set; }
    public bool IsQuickSend { get; set; }
}

public class ErrorMessage : BaseMessage
{
    public ErrorMessage() => Type = MessageType.Error;
    public string Error { get; set; } = string.Empty;
}

public class PairingRequestMessage : BaseMessage
{
    public PairingRequestMessage() => Type = MessageType.PairingRequest;
    public string DeviceName { get; set; } = string.Empty;
    public string PublicKey { get; set; } = string.Empty;
}

public class PairingResponseMessage : BaseMessage
{
    public PairingResponseMessage() => Type = MessageType.PairingResponse;
    public bool Approved { get; set; }
    public string? Reason { get; set; }
}
