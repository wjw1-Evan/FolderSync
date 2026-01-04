using System.Text.RegularExpressions;

namespace FolderSync.Core.Models;

public class SyncFilter
{
    public List<string> ExcludePatterns { get; set; } = new();
    public List<string> IncludePatterns { get; set; } = new();
    public long MinSize { get; set; } = 0;
    public long MaxSize { get; set; } = long.MaxValue;

    public bool IsAllowed(string filePath, long fileSize)
    {
        if (fileSize < MinSize || fileSize > MaxSize) return false;

        string fileName = Path.GetFileName(filePath);

        // Check exclusions first
        foreach (var pattern in ExcludePatterns)
        {
            if (MatchesGlob(fileName, pattern)) return false;
        }

        // If inclusions are defined, strictly require a match
        if (IncludePatterns.Any())
        {
            foreach (var pattern in IncludePatterns)
            {
                if (MatchesGlob(fileName, pattern)) return true;
            }
            return false;
        }

        return true;
    }

    private static bool MatchesGlob(string text, string pattern)
    {
        // Simple glob to regex conversion
        string regexPattern = "^" + Regex.Escape(pattern).Replace("\\*", ".*").Replace("\\?", ".") + "$";
        return Regex.IsMatch(text, regexPattern, RegexOptions.IgnoreCase);
    }
}
