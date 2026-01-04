using System.Windows.Input;

namespace FolderSync.App.Helpers;

public class PickerCommandBehavior : Behavior<Picker>
{
    public static readonly BindableProperty CommandProperty =
        BindableProperty.Create(nameof(Command), typeof(ICommand), typeof(PickerCommandBehavior));

    public static readonly BindableProperty CommandParameterProperty =
        BindableProperty.Create(nameof(CommandParameter), typeof(object), typeof(PickerCommandBehavior));

    public ICommand Command
    {
        get => (ICommand)GetValue(CommandProperty);
        set => SetValue(CommandProperty, value);
    }

    public object CommandParameter
    {
        get => GetValue(CommandParameterProperty);
        set => SetValue(CommandParameterProperty, value);
    }

    protected override void OnAttachedTo(Picker bindable)
    {
        base.OnAttachedTo(bindable);
        bindable.SelectedIndexChanged += OnSelectedIndexChanged;
    }

    protected override void OnDetachingFrom(Picker bindable)
    {
        base.OnDetachingFrom(bindable);
        bindable.SelectedIndexChanged -= OnSelectedIndexChanged;
    }

    private void OnSelectedIndexChanged(object? sender, EventArgs e)
    {
        if (Command != null && Command.CanExecute(CommandParameter))
        {
            Command.Execute(CommandParameter);
        }
    }
}
