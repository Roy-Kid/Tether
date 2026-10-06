using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace TetherApp;

public sealed partial class MainWindow
{
    private readonly HashSet<Tab> _closingTabs = [];
    private bool _zen;
    private bool _windowCloseApproved, _checkingWindowClose;
    private async Task RequestWindowCloseAsync()
    {
        if (_checkingWindowClose) return;
        _checkingWindowClose = true;
        _connecting = true;
        try
        {
            var notes = new List<string>();
            foreach (var tab in _workspace.Tabs.ToArray())
            {
                var note = tab.Attachments.Select(a => a.CloseNote).FirstOrDefault(n => n is not null)
                    ?? await ShellActivity.CloseNoteAsync(tab.Model);
                if (note is not null) notes.Add(tab.Title + ": " + note);
            }
            if (notes.Count > 0 && await Alerts.ContentAsync("Close Window?", string.Join("\n", notes), "Close", null,
                WorkspaceRoot.ActualTheme, _ => { }) != ContentDialogResult.Primary) return;
            _windowCloseApproved = true;
            _workspace.Persist();
            Close();
        }
        finally { _checkingWindowClose = false; _connecting = false; }
    }
    private Window? _commandPicker;

    private void ApplyWorkspaceVisibility()
    {
        var shows = !_zen && AppSettings.Current.ShowsTabBar;
        var vertical = AppSettings.Current.TabLayout == "vertical";
        TabStrip.Visibility = shows && !vertical ? Visibility.Visible : Visibility.Collapsed;
        VerticalTabs.Visibility = shows && vertical ? Visibility.Visible : Visibility.Collapsed;
        HiddenTitleBarDragArea.Visibility = TabStrip.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
        SetTitleBar(TabStrip.Visibility == Visibility.Visible ? TitleBarDragArea : HiddenTitleBarDragArea);
        StatusBar.Visibility = _zen ? Visibility.Collapsed : Visibility.Visible;
        if (_zen) InspectorHost.Visibility = Visibility.Collapsed;
    }

    private sealed record VerticalRow(Tab Tab) { public override string ToString() => Tab.Title; }
    private void RefreshVerticalTabs()
    {
        var rows = _workspace.Tabs.Select(t => new VerticalRow(t)).ToArray();
        VerticalTabList.ItemsSource = rows;
        VerticalTabList.SelectedIndex = _workspace.ActiveIndex;
    }
    private void VerticalTabs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_refreshingTabs && VerticalTabList.SelectedItem is VerticalRow row)
            _workspace.Select(_workspace.Tabs.ToList().IndexOf(row.Tab));
    }
    private async void VerticalAdd_Click(object sender, RoutedEventArgs e) => await _workspace.AddAsync();

    private bool HandleWorkspaceShortcut(Shortcut shortcut)
    {
        foreach (var command in WorkspaceCommands.All)
        {
            if (!Shortcut.TryParse(WorkspaceCommands.Binding(command, AppSettings.Current), out var binding) || binding != shortcut) continue;
            _ = RunCommandAsync(command.Id);
            return true;
        }
        if (_workspace.Active is not { } tab) return false;
        foreach (var plugin in App.Plugins.Plugins.OfType<Plugins.ITabPlugin>().Where(p => App.Plugins.IsEnabled(p.Metadata.Id)))
        {
            var launch = "plugin." + plugin.Metadata.Id + ".launch";
            if (Matches(launch)) { ToggleInspector(plugin.Metadata.Id); return true; }
            foreach (var descriptor in plugin.CommandDescriptors)
            {
                if (!Matches("plugin." + plugin.Metadata.Id + ".command." + descriptor.Id)) continue;
                var attachment = tab.Attach(plugin, Context(tab, plugin));
                if (attachment.Commands.FirstOrDefault(c => c.Id == descriptor.Id) is { } command) _ = command.Run();
                return true;
            }
        }
        return false;
        bool Matches(string id) => AppSettings.Current.KeyBindings.TryGetValue(id, out var chord) && Shortcut.TryParse(chord, out var key) && key == shortcut;
    }

    private async Task RunCommandAsync(string id)
    {
        try
        {
            switch (id)
            {
                case "newTerminal": await _workspace.AddAsync(); break;
                case "changeHost": ShowHostPicker(); break;
                case "closeTab": await CloseSelectedAsync(); break;
                case "restoreTab":
                    if (await _workspace.RestoreAsync() is { } restored)
                    {
                        var title = restored.Tab.Title;
                        if (restored.Host is { } host) await OpenHostAsync(host);
                        _workspace.Rename(restored.Tab, title);
                    }
                    break;
                case "commandMenu": ShowCommandPicker(false); break;
                case "quickSwitch": ShowCommandPicker(true); break;
                case "previousTab": _workspace.Select((_workspace.ActiveIndex - 1 + _workspace.Tabs.Count) % _workspace.Tabs.Count); break;
                case "nextTab": _workspace.Select((_workspace.ActiveIndex + 1) % _workspace.Tabs.Count); break;
                case "renameTerminal":
                    if (_workspace.Active is not { } tab) break;
                    var name = new TextBox { Text = tab.Title, MinWidth = 260 };
                    name.Loaded += (_, _) => { name.Focus(FocusState.Programmatic); name.SelectAll(); };
                    _connecting = true;
                    try
                    {
                        if (await Alerts.ContentAsync("Rename Terminal", name, "Rename", null, WorkspaceRoot.ActualTheme, _ => { }) == ContentDialogResult.Primary &&
                            !string.IsNullOrWhiteSpace(name.Text)) _workspace.Rename(tab, name.Text.Trim());
                    }
                    finally { _connecting = false; }
                    break;
                case "toggleTabBar": (AppSettings.Current with { ShowsTabBar = !AppSettings.Current.ShowsTabBar }).Save(); break;
                case "zen": _zen = !_zen; ApplyWorkspaceVisibility(); if (!_zen) UpdateInspector(); break;
                case "inspector":
                    if (_workspace.Active?.OpenInspector is not null) HideInspector(_workspace.Active);
                    else if (App.Plugins.Plugins.OfType<Plugins.ITabPlugin>().FirstOrDefault(p => App.Plugins.IsEnabled(p.Metadata.Id)) is { } plugin)
                        ToggleInspector(plugin.Metadata.Id);
                    break;
                case "manageHosts": await ShowHostEditorAsync(); break;
                case "manageIdentities": await ShowIdentitiesAsync(); break;
            }
        }
        catch (Exception ex)
        {
            await Alerts.ContentAsync("Unable to complete action", ex.Message, "Close", null, WorkspaceRoot.ActualTheme, _ => { });
        }
    }

    private sealed record PickerRow(string Title, string Search, Func<Task> Run)
    {
        public override string ToString() => Title;
    }

    private void ShowCommandPicker(bool quick)
    {
        if (_commandPicker is not null) { _commandPicker.Activate(); return; }
        var query = new TextBox { PlaceholderText = quick ? "Find a terminal or host…" : "Find a command…" };
        var list = new ListView { MaxHeight = 360, IsItemClickEnabled = true };
        var rows = new List<PickerRow>();
        if (quick)
        {
            foreach (var tab in _workspace.Tabs)
                rows.Add(new(tab.Title, tab.Title, () => { _workspace.Select(_workspace.Tabs.ToList().IndexOf(tab)); return Task.CompletedTask; }));
            foreach (var host in SshConfig.Load()) rows.Add(new(host.Label, host.Label + " " + host.Target, () => OpenHostAsync(host)));
        }
        else
        {
            foreach (var command in WorkspaceCommands.All)
            {
                var chord = WorkspaceCommands.Binding(command, AppSettings.Current);
                rows.Add(new(command.Title + (chord.Length > 0 ? "    " + chord : ""), command.Title + " " + chord, () => RunCommandAsync(command.Id)));
            }
            foreach (var plugin in App.Plugins.Plugins.OfType<Plugins.ITabPlugin>().Where(p => App.Plugins.IsEnabled(p.Metadata.Id)))
            {
                rows.Add(new("Open " + plugin.Metadata.Name, plugin.Metadata.Name, () => { ToggleInspector(plugin.Metadata.Id); return Task.CompletedTask; }));
                if (_workspace.Active is { } tab)
                    foreach (var command in tab.Attach(plugin, Context(tab, plugin)).Commands)
                        rows.Add(new(command.Title, command.Title, command.Run));
            }
        }
        void Reload()
        {
            list.ItemsSource = rows.Where(r => r.Search.Contains(query.Text.Trim(), StringComparison.OrdinalIgnoreCase)).ToArray();
            list.SelectedIndex = list.Items.Count > 0 ? 0 : -1;
        }
        var window = new Window { Title = quick ? "Quick Switch" : "Command Menu" };
        AppBranding.Apply(window);
        async Task Choose(PickerRow row) { window.Close(); await row.Run(); }
        query.TextChanged += (_, _) => Reload();
        list.ItemClick += async (_, e) => { if (e.ClickedItem is PickerRow row) await Choose(row); };
        var panel = new StackPanel { Padding = new Thickness(12), Spacing = 8 };
        panel.Children.Add(query); panel.Children.Add(list);
        panel.KeyDown += async (_, e) =>
        {
            if (e.Key == VirtualKey.Escape) { e.Handled = true; window.Close(); }
            else if (e.Key == VirtualKey.Enter && list.SelectedItem is PickerRow row) { e.Handled = true; await Choose(row); }
            else if (e.Key is VirtualKey.Down or VirtualKey.Up && list.Items.Count > 0)
            { e.Handled = true; list.SelectedIndex = Math.Clamp(list.SelectedIndex + (e.Key == VirtualKey.Down ? 1 : -1), 0, list.Items.Count - 1); list.ScrollIntoView(list.SelectedItem); }
        };
        window.Content = panel;
        window.AppWindow.Resize(new Windows.Graphics.SizeInt32(480, 450));
        WindowPlacement.Own(window);
        window.Closed += (_, _) => { _commandPicker = null; _workspace.Active?.Surface.FocusTerminal(); };
        _commandPicker = window;
        Reload(); window.Activate(); query.Focus(FocusState.Programmatic);
    }

    private async Task ShowHostEditorAsync()
    {
        _connecting = true;
        try { await HostManager.ShowAsync(WorkspaceRoot.ActualTheme, host => _workspace.Tabs.Select(t => t.Model).FirstOrDefault(m =>
            m.IsLive && m.IsRemote && m.RemoteHost is { } current && IdentityStore.EndpointDigest(current) == IdentityStore.EndpointDigest(host)), ChooseHostAsync); }
        finally { _connecting = false; _workspace.Active?.Surface.FocusTerminal(); }
    }
    private async Task ShowIdentitiesAsync()
    {
        _connecting = true;
        try { await IdentityManager.ShowAsync(WorkspaceRoot.ActualTheme); }
        finally { _connecting = false; _workspace.Active?.Surface.FocusTerminal(); }
    }
}
