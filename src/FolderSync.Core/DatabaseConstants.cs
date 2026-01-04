namespace FolderSync.Core;

public static class DatabaseConstants
{
    public const string DatabaseFilename = "FolderSync.db3";

    public static string DatabasePath
    {
        get
        {
            var basePath = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(basePath, "FolderSync", DatabaseFilename);
        }
    }
}
