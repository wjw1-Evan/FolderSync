using System.Globalization;
using FolderSync.Sync.Services;

namespace FolderSync.App.Helpers;

public class DiffTypeConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is DiffType type)
        {
            return type switch
            {
                DiffType.Added => "+",
                DiffType.Removed => "-",
                _ => " "
            };
        }
        return " ";
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotImplementedException();
}

public class DiffColorConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is DiffType type)
        {
            return type switch
            {
                DiffType.Added => Colors.Green,
                DiffType.Removed => Colors.Red,
                _ => Colors.Gray
            };
        }
        return Colors.Gray;
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotImplementedException();
}
