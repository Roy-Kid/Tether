using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TetherApp;

public sealed partial class SettingsWindow
{
    private void BuildQuickTerminalSettings()
    {
        var refreshing = false;
        ToggleSwitch Toggle(string title, bool value, Func<AppSettings, bool, AppSettings> update)
        {
            var control = new ToggleSwitch { Header = title, IsOn = value };
            control.Toggled += (_, _) => { if (!refreshing) ShowSaveResult(update(AppSettings.Current, control.IsOn).Save()); };
            QuickTerminalPane.Children.Add(control);
            return control;
        }
        var enabled = Toggle("Enable Quick Terminal", AppSettings.Current.QuickTerminalEnabled, (s, value) => s with { QuickTerminalEnabled = value });
        var shortcut = new TextBlock();
        QuickTerminalPane.Children.Add(shortcut);
        var keys = new Button { Content = "Change shortcut…" };
        keys.Click += (_, _) => SettingsRoot.SelectedItem = SettingsRoot.MenuItems.OfType<NavigationViewItem>().First(i => i.Tag as string == "keys");
        QuickTerminalPane.Children.Add(keys);
        var autoHide = Toggle("Hide when switching apps", AppSettings.Current.QuickTerminalAutoHide, (s, value) => s with { QuickTerminalAutoHide = value });
        var tray = Toggle("Use notification area for Quick Terminal", AppSettings.Current.QuickTerminalTrayIcon, (s, value) => s with { QuickTerminalTrayIcon = value });
        QuickTerminalPane.Children.Add(new TextBlock
        {
            Text = "The notification-area icon stays while Tether is running. Closing the window hides it there; Quit ends sessions.",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.7,
        });
        var problem = new TextBlock { TextWrapping = TextWrapping.Wrap };
        QuickTerminalPane.Children.Add(problem);
        var show = new Button { Content = "Show / Hide Quick Terminal" };
        show.Click += (_, _) => QuickTerminalController.Current?.Toggle();
        QuickTerminalPane.Children.Add(show);
        var restore = new Button { Content = "Restore normal window" };
        restore.Click += (_, _) => QuickTerminalController.Current?.Restore();
        QuickTerminalPane.Children.Add(restore);
        var topmost = Toggle("Keep normal window on top", AppSettings.Current.AlwaysOnTop, (s, value) => s with { AlwaysOnTop = value });
        void Refresh()
        {
            refreshing = true;
            enabled.IsOn = AppSettings.Current.QuickTerminalEnabled;
            autoHide.IsOn = AppSettings.Current.QuickTerminalAutoHide;
            tray.IsOn = AppSettings.Current.QuickTerminalTrayIcon;
            topmost.IsOn = AppSettings.Current.AlwaysOnTop;
            refreshing = false;
            var controller = QuickTerminalController.Current;
            var command = WorkspaceCommands.All.Single(c => c.Id == "quickTerminal");
            shortcut.Text = "Global shortcut: " + string.Join(" / ", WorkspaceCommands.Bindings(command, AppSettings.Current));
            problem.Text = controller?.Problem ?? "";
            autoHide.IsEnabled = tray.IsEnabled = AppSettings.Current.QuickTerminalEnabled;
            show.IsEnabled = AppSettings.Current.QuickTerminalEnabled && controller is not null;
            restore.IsEnabled = controller?.IsQuick == true;
        }
        QuickTerminalController.Changed += Refresh;
        Closed += (_, _) => QuickTerminalController.Changed -= Refresh;
        Refresh();
    }
}
