using FolderSync.Core.Models.Messages;

namespace FolderSync.Core.Models.Messages;

public class QuickSendMessage : BaseMessage
{
    public QuickSendMessage()
    {
        Type = MessageType.QuickSend;
    }
    
    public string FileName { get; set; } = string.Empty;
    public long FileSize { get; set; }
    public string? Hash { get; set; }
    public bool IsQuickSend { get; set; } = true;
}
