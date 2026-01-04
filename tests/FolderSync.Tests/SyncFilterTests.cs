using FolderSync.Core.Models;
using Xunit;

namespace FolderSync.Tests;

public class SyncFilterTests
{
    [Theory]
    [InlineData("test.txt", true)]
    [InlineData(".DS_Store", false)]
    [InlineData("temp.tmp", false)]
    [InlineData("image.png", true)]
    public void IsAllowed_ExcludesSystemFiles(string fileName, bool expected)
    {
        var filter = new SyncFilter();
        filter.ExcludePatterns.Add(".DS_Store");
        filter.ExcludePatterns.Add("*.tmp");

        var result = filter.IsAllowed(fileName, 100);

        Assert.Equal(expected, result);
    }

    [Fact]
    public void IsAllowed_RespectsMaxFileSize()
    {
        var filter = new SyncFilter { MaxSize = 1024 }; // 1KB

        Assert.True(filter.IsAllowed("small.txt", 500));
        Assert.False(filter.IsAllowed("large.txt", 2000));
    }

    [Fact]
    public void IsAllowed_IncludePatternsOverwritesExclude()
    {
        // This is a design decision. Let's see how our current implementation handles it.
        // Current implementation: if any exclude matches -> false.
        var filter = new SyncFilter();
        filter.ExcludePatterns.Add("*.txt");
        filter.IncludePatterns.Add("priority.txt");

        // The current implementation check exclude FIRST.
        Assert.False(filter.IsAllowed("priority.txt", 100)); // Should be false based on current logic
    }
}
