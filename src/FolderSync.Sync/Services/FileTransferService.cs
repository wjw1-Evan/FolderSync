using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.IO.Compression;
using FolderSync.Core.Interfaces;
using FolderSync.Core.Models.Messages;

namespace FolderSync.Sync.Services;

public class FileTransferService : IFileTransferService
{
    private TcpListener? _listener;
    private bool _isListening;
    private const int ChunkSize = 1024 * 1024; // 1MB
    private readonly IHashService _hashService;
    private readonly IEncryptionService _encryptionService;
    private const string DefaultPassword = "FolderSyncSecureTransferPassword";

    public event EventHandler<TransferProgressEventArgs>? TransferProgress;
    public event EventHandler<FileReceivedEventArgs>? FileReceived;

    public FileTransferService(IHashService hashService, IEncryptionService encryptionService)
    {
        _hashService = hashService;
        _encryptionService = encryptionService;
    }

    public async Task StartListenerAsync(int port)
    {
        _listener = new TcpListener(IPAddress.Any, port);
        _listener.Start();
        _isListening = true;

        _ = Task.Run(async () =>
        {
            try
            {
                while (_isListening)
                {
                    var client = await _listener.AcceptTcpClientAsync();
                    _ = HandleIncomingConnection(client);
                }
            }
            catch (Exception ex) when (_isListening)
            {
                Console.WriteLine($"Listener error: {ex.Message}");
            }
        });
    }

    public void StopListener()
    {
        _isListening = false;
        _listener?.Stop();
    }

    private async Task HandleIncomingConnection(TcpClient client)
    {
        try
        {
            using (client)
            using (var netStream = client.GetStream())
            // Use decryption stream
            using (var stream = await _encryptionService.GetDecryptionStreamAsync(netStream, DefaultPassword))
            {
                // 1. Read metadata length
                byte[] lengthBuffer = new byte[4];
                await stream.ReadExactlyAsync(lengthBuffer, 0, 4);
                int metaLength = BitConverter.ToInt32(lengthBuffer, 0);

                // 2. Read metadata
                byte[] metaBuffer = new byte[metaLength];
                await stream.ReadExactlyAsync(metaBuffer, 0, metaLength);
                string metaJson = Encoding.UTF8.GetString(metaBuffer);
                var metadata = JsonSerializer.Deserialize<FileTransferMetadata>(metaJson);

                if (metadata == null) return;

                // 3. Setup temp file
                string tempDir = Path.Combine(Path.GetTempPath(), "FolderSync");
                if (!Directory.Exists(tempDir)) Directory.CreateDirectory(tempDir);
                
                string tempPath = Path.Combine(tempDir, $"{metadata.Hash}.part");
                
                FileMode mode = metadata.IsResuming ? FileMode.Append : FileMode.Create;
                
                using (var fileStream = new FileStream(tempPath, mode, FileAccess.Write))
                {
                    byte[] buffer = new byte[ChunkSize];
                    long totalReceived = metadata.Offset;
                    long bytesToRead = metadata.Size - metadata.Offset;

                    Stream dataStream = stream;
                    GZipStream? decompressor = null;

                    if (metadata.UseCompression)
                    {
                        decompressor = new GZipStream(stream, CompressionMode.Decompress, leaveOpen: true);
                        dataStream = decompressor;
                    }

                    try
                    {
                        while (bytesToRead > 0)
                        {
                            int toRead = (int)Math.Min(ChunkSize, bytesToRead);
                            int read = await dataStream.ReadAsync(buffer, 0, toRead);
                            if (read == 0) break;

                            await fileStream.WriteAsync(buffer, 0, read);
                            totalReceived += read;
                            bytesToRead -= read;

                            TransferProgress?.Invoke(this, new TransferProgressEventArgs
                            {
                                FileName = metadata.RelativePath,
                                BytesTransferred = totalReceived,
                                TotalBytes = metadata.Size
                            });
                        }
                    }
                    finally
                    {
                        if (decompressor != null) await decompressor.DisposeAsync();
                    }
                }
                
                // 4. Verify hash and notify
                if (new FileInfo(tempPath).Length == metadata.Size)
                {
                    var receivedHash = await _hashService.ComputeFileHashAsync(tempPath);
                    if (receivedHash == metadata.Hash)
                    {
                        FileReceived?.Invoke(this, new FileReceivedEventArgs
                        {
                            TempPath = tempPath,
                            Metadata = metadata
                        });
                    }
                    else
                    {
                        Console.WriteLine($"Hash mismatch for {metadata.RelativePath}. Deleting corrupt part.");
                        File.Delete(tempPath);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error handling incoming transfer: {ex.Message}");
        }
    }

    public async Task SendFileAsync(string filePath, string relativePath, string targetIp, int targetPort, string deviceId, long requestedOffset = 0, bool isQuickSend = false)
    {
        if (!File.Exists(filePath)) throw new FileNotFoundException(filePath);

        var fileInfo = new FileInfo(filePath);
        var hash = await _hashService.ComputeFileHashAsync(filePath);

        var metadata = new FileTransferMetadata
        {
            RelativePath = relativePath,
            Hash = hash,
            Size = fileInfo.Length,
            Offset = requestedOffset,
            IsResuming = requestedOffset > 0,
            IsQuickSend = isQuickSend,
            UseCompression = ShouldCompress(filePath),
            DeviceId = deviceId
        };

        string metaJson = JsonSerializer.Serialize(metadata);
        byte[] metaBytes = Encoding.UTF8.GetBytes(metaJson);
        byte[] lengthBytes = BitConverter.GetBytes(metaBytes.Length);

        using var client = new TcpClient();
        await client.ConnectAsync(targetIp, targetPort);
        using var netStream = client.GetStream();
        
        // Wrap in encryption stream
        using (var stream = _encryptionService.GetEncryptionStream(netStream, DefaultPassword))
        {
            // 1. Send metadata
            await stream.WriteAsync(lengthBytes, 0, 4);
            await stream.WriteAsync(metaBytes, 0, metaBytes.Length);

            // 2. Send content from offset
            using var fileStream = File.OpenRead(filePath);
            if (requestedOffset > 0) fileStream.Seek(requestedOffset, SeekOrigin.Begin);

            Stream dataStream = stream;
            GZipStream? compressor = null;

            if (metadata.UseCompression)
            {
                compressor = new GZipStream(stream, CompressionLevel.Optimal, leaveOpen: true);
                dataStream = compressor;
            }

            try
            {
                byte[] buffer = new byte[ChunkSize];
                long bytesSent = requestedOffset;
                int read;
                while ((read = await fileStream.ReadAsync(buffer, 0, buffer.Length)) > 0)
                {
                    await dataStream.WriteAsync(buffer, 0, read);
                    bytesSent += read;

                    TransferProgress?.Invoke(this, new TransferProgressEventArgs
                    {
                        FileName = relativePath,
                        BytesTransferred = bytesSent,
                        TotalBytes = fileInfo.Length
                    });
                }
                await dataStream.FlushAsync();
            }
            finally
            {
                if (compressor != null) await compressor.DisposeAsync();
            }

            // Flush encryption stream
            await stream.FlushAsync();
        }
    }

    public async Task<string> ReceiveFileAsync(string expectedHash, string tempPath)
    {
        return tempPath;
    }

    private static bool ShouldCompress(string filePath)
    {
        var ext = Path.GetExtension(filePath).ToLowerInvariant();
        string[] noCompress = { ".jpg", ".jpeg", ".png", ".gif", ".zip", ".7z", ".rar", ".mp4", ".mp3", ".pdf", ".gz" };
        return !noCompress.Contains(ext);
    }
}
