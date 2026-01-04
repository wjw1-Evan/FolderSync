using FolderSync.Sync.Models;
using FolderSync.Sync.Services;
using FolderSync.Data.Entities;
using Xunit;

namespace FolderSync.Tests;

public class SyncQueueTests
{
    [Fact]
    public void Dequeue_ReturnsHighPriorityFirst()
    {
        var queue = new SyncQueueService();
        var taskLow = new SyncTask { FilePath = "low.txt", Priority = SyncPriority.Low };
        var taskHigh = new SyncTask { FilePath = "high.txt", Priority = SyncPriority.High };
        var taskMed = new SyncTask { FilePath = "med.txt", Priority = SyncPriority.Medium };

        queue.Enqueue(taskLow);
        queue.Enqueue(taskHigh);
        queue.Enqueue(taskMed);

        var first = queue.Dequeue();
        var second = queue.Dequeue();
        var third = queue.Dequeue();

        Assert.Equal("high.txt", first?.FilePath);
        Assert.Equal("med.txt", second?.FilePath);
        Assert.Equal("low.txt", third?.FilePath);
    }
}
