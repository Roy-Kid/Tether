using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TetherApp.Plugins;
using Windows.System;

namespace TetherApp;

public sealed partial class MainWindow
{
    private bool _paletteQuick;
    private sealed record PickerRow(string Title, string Search, Func<Task> Run, bool Enabled = true)
    {
        public override string ToString() => Title;
    }

    private void ShowCommandPicker(bool quick)
    {
        if (_commandPicker is not null)
        {
            _commandPicker.Close();
            if (_paletteQuick == quick) return;
        }
        _paletteQuick = quick;
        var query = new TextBox { PlaceholderText = quick ? "Find a terminal or host…" : "Find a command…" };
        var list = new ListView { MaxHeight = 360, IsItemClickEnabled = true };
        list.ItemContainerStyle = new Style(typeof(ListViewItem))
        {
            Setters = { new Setter(Control.IsEnabledProperty, new Microsoft.UI.Xaml.Data.Binding
            { Path = new PropertyPath(nameof(PickerRow.Enabled)) }) },
        };
        var rows = new List<PickerRow>();
        if (quick)
        {
            foreach (var tab in _workspace.Tabs)
                foreach (var terminal in tab.Panes)
                {
                    var title = (tab.Host?.Label ?? "localhost") + " / " + tab.Title + " / " + terminal.Title;
                    rows.Add(new(title, title, () => { _workspace.Activate(tab); _workspace.Focus(terminal); return Task.CompletedTask; }));
                }
            foreach (var extension in _workspace.Extensions)
                rows.Add(new(extension.Title, "extension " + extension.Title + " " + extension.PluginId,
                    () => { _workspace.Activate(extension); return Task.CompletedTask; }));
            IReadOnlyList<HostEntry> hosts;
            try { hosts = SshConfig.Load(); }
            catch { hosts = []; }
            foreach (var alias in AppSettings.Current.RecentHosts.Take(5))
            {
                if (alias == "local")
                    rows.Add(new("Recent · localhost", "\0recent localhost local", () => ChooseHostAsync(null)));
                else if (hosts.FirstOrDefault(h => h.Alias == alias) is { } recent)
                    rows.Add(new("Recent · " + recent.Label, "\0recent " + recent.Label + " " + recent.Target,
                        () => ChooseHostAsync(recent)));
            }
            rows.Add(new("Host / localhost", "host localhost local", () => ChooseHostAsync(null)));
            foreach (var host in hosts) rows.Add(new("Host / " + host.Label, host.Label + " " + host.Target, () => ChooseHostAsync(host)));
        }
        else
        {
            foreach (var command in WorkspaceCommands.All)
            {
                var chords = string.Join("  ", WorkspaceCommands.Bindings(command, AppSettings.Current));
                rows.Add(new(CommandTitle(command) + (chords.Length > 0 ? "    " + chords : ""), command.Title + " " + chords,
                    () => RunCommandAsync(command.Id), CommandEnabled(command.Id)));
            }
            foreach (var plugin in App.Plugins.Plugins.OfType<Plugins.ITabPlugin>().Where(p => App.Plugins.IsEnabled(p.Metadata.Id)))
            {
                rows.Add(new("Open " + plugin.Metadata.Name, plugin.Metadata.Name, () =>
                {
                    if (_workspace.Active is null || plugin is WebPlugin) OpenExtensionTab(plugin.Metadata.Id);
                    else ToggleInspector(plugin.Metadata.Id);
                    return Task.CompletedTask;
                }));
                if (_workspace.Active is not null && plugin is WebPlugin)
                    rows.Add(new("Inspect " + plugin.Metadata.Name, "inspector " + plugin.Metadata.Name,
                        () => { ToggleInspector(plugin.Metadata.Id); return Task.CompletedTask; }));
                if (_workspace.Active is { } tab)
                    foreach (var descriptor in plugin.CommandDescriptors)
                        rows.Add(new(descriptor.Title, plugin.Metadata.Name + " " + descriptor.Title, () =>
                        {
                            var attachment = tab.Attach(plugin, Context(tab, plugin));
                            return attachment.Commands.FirstOrDefault(c => c.Id == descriptor.Id) is { } command
                                ? RunPluginCommandAsync(command.Run) : Task.CompletedTask;
                        }));
            }
        }
        void Reload()
        {
            var empty = string.IsNullOrWhiteSpace(query.Text);
            list.ItemsSource = rows.Where(r =>
                (empty || !r.Search.StartsWith('\0')) && CommandSearch.Matches(query.Text, r.Search.TrimStart('\0'))).ToArray();
            list.SelectedIndex = list.Items.Cast<PickerRow>().ToList().FindIndex(r => r.Enabled);
        }
        var window = new Window { Title = quick ? "Quick Switch" : "Command Palette" };
        AppBranding.Apply(window);
        async Task Choose(PickerRow row) { if (!row.Enabled) return; window.Close(); await RunPluginCommandAsync(row.Run); }
        query.TextChanged += (_, _) => Reload();
        list.ItemClick += async (_, e) => { if (e.ClickedItem is PickerRow row) await Choose(row); };
        var panel = new StackPanel { Padding = new Thickness(12), Spacing = 8, RequestedTheme = WorkspaceRoot.ActualTheme,
            Background = (Brush)Application.Current.Resources["ChromeRaisedBrush"] };
        panel.Children.Add(query); panel.Children.Add(list);
        panel.KeyDown += async (_, e) =>
        {
            bool Down(VirtualKey key) => Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key)
                .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            var shortcut = new Shortcut(e.Key, Down(VirtualKey.Shift), Down(VirtualKey.Control), Down(VirtualKey.Menu));
            var command = WorkspaceCommands.All.FirstOrDefault(c => (WorkspaceCommands.AnswersWhileEditing(c.Id) || c.Id == "closeTab") &&
                WorkspaceCommands.Matches(c, AppSettings.Current, shortcut));
            if (command is not null)
            {
                e.Handled = true;
                if (command.Id == "closeTab") window.Close();
                else ShowCommandPicker(command.Id == "quickSwitch");
                return;
            }
            if (e.Key == VirtualKey.Escape) { e.Handled = true; window.Close(); }
            else if (e.Key == VirtualKey.Enter && list.SelectedItem is PickerRow row) { e.Handled = true; await Choose(row); }
            else if (e.Key is VirtualKey.Down or VirtualKey.Up && list.Items.Count > 0)
            {
                e.Handled = true;
                var step = e.Key == VirtualKey.Down ? 1 : -1;
                var next = list.SelectedIndex + step;
                while (next >= 0 && next < list.Items.Count && !((PickerRow)list.Items[next]).Enabled) next += step;
                if (next >= 0 && next < list.Items.Count) { list.SelectedIndex = next; list.ScrollIntoView(list.SelectedItem); }
            }
        };
        window.Content = panel;
        window.AppWindow.Resize(new Windows.Graphics.SizeInt32(480, 450));
        WindowPlacement.Own(window);
        WindowPlacement.Center(window, 480, 450);
        window.Closed += (_, _) =>
        {
            if (_commandPicker == window) _commandPicker = null;
            DispatcherQueue.TryEnqueue(() => { if (_commandPicker is null && _hostPicker is null && !_connecting) _workspace.Active?.Surface.FocusTerminal(); });
        };
        _commandPicker = window;
        Reload(); window.Activate(); query.Focus(FocusState.Programmatic);
    }

}
