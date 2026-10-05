using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TetherApp;

internal static class EditorDialog
{
    public static async Task<bool> ShowAsync(string title, StackPanel fields, Func<Task> save, string verb = "Save", Func<bool>? busy = null)
    {
        var done = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var window = new Window { Title = title };
        var root = new Grid { Padding = new Thickness(20), RowSpacing = 12, RequestedTheme = Appearance.RequestedTheme,
            Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["ChromeWindowBrush"] };
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.Children.Add(new ScrollViewer { Content = fields, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        var problem = new TextBlock { TextWrapping = TextWrapping.Wrap }; Grid.SetRow(problem, 1); root.Children.Add(problem);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = "Cancel", Visibility = verb == "Done" ? Visibility.Collapsed : Visibility.Visible };
        var apply = new Button { Content = verb == "Done" ? "Close" : verb };
        cancel.Click += (_, _) => window.Close();
        async Task Apply()
        {
            if (!apply.IsEnabled) return;
            apply.IsEnabled = cancel.IsEnabled = false; problem.Text = "";
            try { await save(); apply.IsEnabled = cancel.IsEnabled = true; done.TrySetResult(true); window.Close(); }
            catch (Exception ex) { problem.Text = ex.Message; }
            finally { apply.IsEnabled = cancel.IsEnabled = true; }
        }
        apply.Click += async (_, _) => await Apply();
        buttons.Children.Add(cancel); buttons.Children.Add(apply); Grid.SetRow(buttons, 2); root.Children.Add(buttons);
        root.KeyDown += async (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Escape && cancel.IsEnabled) { e.Handled = true; window.Close(); }
            else if (e.Key == Windows.System.VirtualKey.Enter &&
                Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down))
            { e.Handled = true; await Apply(); }
        };
        window.Closed += (_, _) => done.TrySetResult(false);
        window.AppWindow.Closing += (_, e) => { if (!apply.IsEnabled || busy?.Invoke() == true) e.Cancel = true; };
        window.Content = root; window.AppWindow.Resize(new Windows.Graphics.SizeInt32(520, 650));
        WindowPlacement.Own(window); WindowPlacement.Center(window, 520, 650); window.Activate();
        return await done.Task;
    }
    public static Button Icon(string glyph, string name, Action run)
    {
        var button = new Button { Content = glyph, FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Segoe Fluent Icons") };
        ToolTipService.SetToolTip(button, name); Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, name);
        button.Click += (_, _) => run(); return button;
    }
}
