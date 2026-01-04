namespace FolderSync.Sync.Services;

public class DiffResult
{
    public List<DiffLine> Lines { get; set; } = new();
}

public class DiffLine
{
    public string Content { get; set; } = string.Empty;
    public DiffType Type { get; set; }
}

public enum DiffType
{
    Unchanged,
    Added,
    Removed
}

public interface IDiffService
{
    DiffResult Compare(string oldText, string newText);
}

public class DiffService : IDiffService
{
    public DiffResult Compare(string oldText, string newText)
    {
        var result = new DiffResult();
        var oldLines = oldText.Split(new[] { "\r\n", "\r", "\n" }, StringSplitOptions.None);
        var newLines = newText.Split(new[] { "\r\n", "\r", "\n" }, StringSplitOptions.None);

        // Simple line-by-line comparison (not a full LCS, but good for simple text)
        // For a real app, use a library like DiffPlex.
        // We will implement a basic version for now.
        
        int i = 0, j = 0;
        while (i < oldLines.Length || j < newLines.Length)
        {
            if (i < oldLines.Length && j < newLines.Length && oldLines[i] == newLines[j])
            {
                result.Lines.Add(new DiffLine { Content = oldLines[i], Type = DiffType.Unchanged });
                i++; j++;
            }
            else if (j < newLines.Length && (i >= oldLines.Length || !oldLines.Skip(i).Contains(newLines[j])))
            {
                result.Lines.Add(new DiffLine { Content = newLines[j], Type = DiffType.Added });
                j++;
            }
            else if (i < oldLines.Length)
            {
                result.Lines.Add(new DiffLine { Content = oldLines[i], Type = DiffType.Removed });
                i++;
            }
        }

        return result;
    }
}
