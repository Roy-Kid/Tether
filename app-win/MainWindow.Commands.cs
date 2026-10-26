using Microsoft.UI.Xaml;
using TetherApp.Plugins;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace TetherApp;

public sealed partial class MainWindow
{
    private FrameworkElement? _dragArea;
    private readonly HashSet<Tab> _closingTabs = [];
    private bool _zen;
    private bool _windowCloseApproved, _checkingWindowClose;
    private void ShowFromBackground()
    {
        if (_quickTerminal?.IsQuick == true) _quickTerminal.Restore();
        AppWindow.Show();
        Activate();
    }

    private void BindTrayQuickTerminal()
    {
        _tray?.BindQuickTerminal(
            () => DispatcherQueue.TryEnqueue(ShowFromBackground),
            () => DispatcherQueue.TryEnqueue(() => _ = QuitAsync()),
            () => DispatcherQueue.TryEnqueue(() => _quickTerminal?.Toggle()),
            () => DispatcherQueue.TryEnqueue(() => _quickTerminal?.Restore()),
            () => DispatcherQueue.TryEnqueue(() =>
                (AppSettings.Current with { AlwaysOnTop = !AppSettings.Current.AlwaysOnTop }).Save()),
            () => _quickTerminal?.IsVisible == true,
            () => _quickTerminal?.IsQuick == true,
            () => AppSettings.Current.AlwaysOnTop,
            () => AppSettings.Current.QuickTerminalEnabled && AppSettings.Current.QuickTerminalTrayIcon);
    }

    private WorkspaceCommandState CommandState => new(_workspace.VisibleTabs.Count + _workspace.VisibleExtensions.Count,
        _workspace.ActiveGroup?.Panes.Count ?? 0, _workspace.ActiveGroup?.Layout.Leaves.Count() ?? 0,
        _workspace.Active?.Model.IsLive == true, _workspace.Active?.Model.CanReconnect == true,
        _workspace.CanRestore, _connecting || _splitting,
        _workspace.Active?.Surface.ActualWidth >= 325, _workspace.Active?.Surface.ActualHeight >= 205,
        _zen, App.Plugins.Plugins.OfType<Plugins.ITabPlugin>().Any(p => App.Plugins.IsEnabled(p.Metadata.Id)),
        _workspace.ActiveExtension is not null);

    private string CommandTitle(WorkspaceCommand command) => command.Id switch
    {
        "alwaysOnTop" => AppSettings.Current.AlwaysOnTop ? "Stop Keeping Window on Top" : command.Title,
        "zen" => _zen ? "Exit Zen Mode" : "Zen Mode",
        "toggleTabBar" => AppSettings.Current.ShowsTabBar ? "Hide Tab Bar" : "Show Tab Bar",
        "reconnect" => _workspace.Active?.Model.RemoteHost is null ? "Restart" : "Reconnect",
        _ => command.Title,
    };

    private bool CommandEnabled(string id) => WorkspaceCommands.IsEnabled(id, CommandState) && id switch
    {
        "quickTerminal" => AppSettings.Current.QuickTerminalEnabled,
        "restoreWindow" => _quickTerminal?.IsQuick == true,
        _ => true,
    };

    private async Task<bool> ConnectPaneAsync(TerminalPane pane, HostEntry host)
    {
        await OpenHostAsync(host, pane);
        // A failed new pane is disposed before entering the workspace. Report
        // its error here, while it still exists, rather than losing it with
        // the pane and leaving an apparently unresponsive host picker.
        await ReportConnectionFailureAsync(pane);
        return pane.Model.IsLive;
    }

    /// Quit from the notification area: the question the window's close asks.
    private Task QuitAsync() => RequestWindowCloseAsync();

    private Task ReportConnectionFailureAsync(TerminalPane pane) =>
        !pane.Model.IsLive && pane.Model.RemoteHost is { } host && pane.Model.LastError is { Length: > 0 } error
            ? Alerts.ConnectionErrorAsync(DispatcherQueue, host.Label, error)
            : Task.CompletedTask;

    private async Task RequestWindowCloseAsync()
    {
        if (_checkingWindowClose) return;
        _checkingWindowClose = true;
        _connecting = true;
        try
        {
            var notes = new List<string>();
            foreach (var tab in _workspace.AllPanes.ToArray())
            {
                var note = await CloseNotesAsync(tab);
                if (note is not null) notes.Add(tab.Title + ": " + note);
            }
            if (notes.Count > 0 && await Alerts.ContentAsync("Quit Tether?", string.Join("\n", notes), "Quit", null,
                WorkspaceRoot.ActualTheme, _ => { }) != ContentDialogResult.Primary) return;
            _windowCloseApproved = true;
            _workspace.Persist();
            Close();
        }
        finally { _checkingWindowClose = false; _connecting = false; }
    }
    private async void SplitLeft_Click(object sender, RoutedEventArgs e) => await RunCommandAsync("splitLeft");
    private async void SplitRight_Click(object sender, RoutedEventArgs e) => await RunCommandAsync("splitRight");
    private async void SplitUp_Click(object sender, RoutedEventArgs e) => await RunCommandAsync("splitUp");
    private async void SplitDown_Click(object sender, RoutedEventArgs e) => await RunCommandAsync("splitDown");
    private async void MaximizePane_Click(object sender, RoutedEventArgs e) => await RunCommandAsync("maximizePane");
    private Window? _commandPicker;

    private void CycleWorkspaceTab(bool forward)
    {
        var items = _workspace.VisibleTabs.Cast<object>().Concat(_workspace.VisibleExtensions).ToList();
        if (items.Count == 0) return;
        var current = _workspace.ActiveExtension is { } extension ? (object)extension
            : _workspace.ActiveGroup is { } group ? group : null;
        var index = current is null ? -1 : items.IndexOf(current);
        var next = items[(index + (forward ? 1 : items.Count - 1) + items.Count) % items.Count];
        if (next is ExtensionTab open) _workspace.Activate(open);
        else if (next is Tab tab) _workspace.Activate(tab);
    }

    private void ApplyWorkspaceVisibility()
    {
        var shows = !_zen && AppSettings.Current.ShowsTabBar;
        var vertical = AppSettings.Current.TabLayout == "vertical";
        TabStrip.Visibility = shows && !vertical ? Visibility.Visible : Visibility.Collapsed;
        VerticalTabs.Visibility = shows && vertical ? Visibility.Visible : Visibility.Collapsed;
        HiddenTitleBarDragArea.Visibility = TabStrip.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
        var dragArea = TabStrip.Visibility == Visibility.Visible ? TitleBarDragArea : HiddenTitleBarDragArea;
        if (!ReferenceEquals(_dragArea, dragArea))
        {
            SetTitleBar(dragArea);
            _dragArea = dragArea;
        }
        var attention = _workspace.Active?.Model.Bar.Phase is RemotePhase.Connecting or RemotePhase.Authenticating or RemotePhase.Lost or RemotePhase.Failed;
        StatusBar.Visibility = !_zen || attention ? Visibility.Visible : Visibility.Collapsed;
        if (_zen) InspectorHost.Visibility = Visibility.Collapsed;
        UpdateTabBarToggle();
    }

    private abstract record VerticalItem(string Title)
    {
        public virtual string Subtitle => "";
        public override string ToString() => Title;
    }
    private sealed record VerticalPaneRow(TerminalPane Pane, string Title) : VerticalItem(Title);
    private sealed record VerticalExtensionRow(ExtensionTab Extension) : VerticalItem(Extension.Title)
    {
        public override string Subtitle => Extension.Subtitle;
    }
    private void RefreshVerticalTabs()
    {
        var rows = _workspace.VisiblePanes.Select(pane => (VerticalItem)new VerticalPaneRow(pane, _workspace.DisplayTitle(pane)))
            .Concat(_workspace.VisibleExtensions.Select(e => new VerticalExtensionRow(e))).ToArray();
        VerticalTabList.ItemsSource = rows;
        VerticalTabList.SelectedItem = _workspace.ActiveExtension is { } extension
            ? rows.OfType<VerticalExtensionRow>().FirstOrDefault(r => r.Extension == extension)
            : rows.OfType<VerticalPaneRow>().FirstOrDefault(r => r.Pane == _workspace.Active);
    }
    private void VerticalTabs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_refreshingTabs) return;
        if (VerticalTabList.SelectedItem is VerticalExtensionRow extension) _workspace.Activate(extension.Extension);
        else if (VerticalTabList.SelectedItem is VerticalPaneRow row) _workspace.Focus(row.Pane);
    }
    private async void VerticalAdd_Click(object sender, RoutedEventArgs e) => await RunCommandAsync("newTab");

    private bool HandleWorkspaceShortcut(Shortcut shortcut)
    {
        // Commands offered by an active attachment own their configured chord.
        if (_workspace.Active is { } active)
            foreach (var plugin in App.Plugins.Plugins.OfType<Plugins.ITabPlugin>().Where(p => App.Plugins.IsEnabled(p.Metadata.Id)))
                foreach (var command in active.AttachmentFor(plugin.Metadata.Id)?.Commands ?? [])
                {
                    var id = "plugin." + plugin.Metadata.Id + ".command." + command.Id;
                    var chords = new[]
                    {
                        AppSettings.Current.KeyBindings.GetValueOrDefault(id),
                        AppSettings.Current.KeyBindings.GetValueOrDefault(WorkspaceCommands.SecondaryKey(id)),
                    };
                    if (!chords.Any(chord => !string.IsNullOrWhiteSpace(chord) && Shortcut.TryParse(chord, out var key) && key == shortcut))
                        continue;
                    _ = RunPluginCommandAsync(command.Run);
                    return true;
                }
        foreach (var command in WorkspaceCommands.All)
        {
            if (!WorkspaceCommands.Matches(command, AppSettings.Current, shortcut)) continue;
            if (command.Id == "quickTerminal")
            {
                if (!AppSettings.Current.QuickTerminalEnabled) continue;
                if (_quickTerminal?.OwnsShortcut(shortcut) == true) return true; // WM_HOTKEY owns this chord.
            }
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
        if (!CommandEnabled(id)) return;
        try
        {
            switch (id)
            {
                case "newTerminal": await _workspace.AddTerminalAsync(ConnectPaneAsync); break;
                case "newTab": await _workspace.AddAsync(ConnectPaneAsync); break;
                case "changeHost": ShowHostPicker(); break;
                case "closeTab": await CloseSelectedAsync(); break;
                case "closeWorkspace": if (_workspace.ActiveGroup is { } group) await CloseTabAsync(group); break;
                case "closeWindow": await RequestWindowCloseAsync(); break;
                case "joinGroups": _workspace.JoinSplits(); break;
                case "previousTerminal": _workspace.CycleTerminal(false); break;
                case "nextTerminal": _workspace.CycleTerminal(true); break;
                case "reconnect": await ReconnectSelectedAsync(); break;
                case "splitLeft": await SplitSelectedAsync(SplitEdge.Left); break;
                case "splitRight": await SplitSelectedAsync(SplitEdge.Right); break;
                case "splitUp": await SplitSelectedAsync(SplitEdge.Up); break;
                case "splitDown": await SplitSelectedAsync(SplitEdge.Down); break;
                case "maximizePane":
                    if (_workspace.ActiveGroup is { } active) { active.Maximized = !active.Maximized; OnWorkspaceChanged(); _workspace.Active?.Surface.FocusTerminal(); }
                    break;
                case "focusLeft": FocusPane(-1, 0); break;
                case "focusRight": FocusPane(1, 0); break;
                case "focusUp": FocusPane(0, -1); break;
                case "focusDown": FocusPane(0, 1); break;
                case "restoreTab":
                    if (await _workspace.RestoreAsync(async (pane, host) => { await OpenHostAsync(host, pane); return pane.Model.IsLive; }) is { } restored)
                    {
                        var title = restored.Tab.Title;
                        if (restored.Host is { } host) await OpenHostAsync(host);
                        _workspace.Rename(restored.Tab, title);
                    }
                    break;
                case "quickTerminal": _quickTerminal?.Toggle(); break;
                case "restoreWindow": _quickTerminal?.Restore(); break;
                case "alwaysOnTop": (AppSettings.Current with { AlwaysOnTop = !AppSettings.Current.AlwaysOnTop }).Save(); break;
                case "commandMenu": ShowCommandPicker(false); break;
                case "quickSwitch": ShowCommandPicker(true); break;
                case "previousTab": CycleWorkspaceTab(false); break;
                case "nextTab": CycleWorkspaceTab(true); break;
                case "renameTerminal":
                case "renameTab":
                    if (_workspace.Active is not { } tab) break;
                    var seed = id == "renameTab" ? _workspace.DisplayTitle(_workspace.ActiveGroup!) : _workspace.RenameSeed(tab);
                    var name = new TextBox { Text = seed, MinWidth = 260 };
                    name.Loaded += (_, _) => { name.Focus(FocusState.Programmatic); name.SelectAll(); };
                    _connecting = true;
                    try
                    {
                        if (await Alerts.ContentAsync("Rename Terminal", name, "Rename", null, WorkspaceRoot.ActualTheme, _ => { }) == ContentDialogResult.Primary &&
                            !string.IsNullOrWhiteSpace(name.Text))
                        {
                            if (id == "renameTab" && _workspace.ActiveGroup is { } namedGroup) _workspace.Rename(namedGroup, name.Text.Trim());
                            else _workspace.Rename(tab, name.Text.Trim());
                        }
                    }
                    finally { _connecting = false; }
                    break;
                case "toggleTabBar": (AppSettings.Current with { ShowsTabBar = !AppSettings.Current.ShowsTabBar }).Save(); break;
                case "zen": _zen = !_zen; ApplyWorkspaceVisibility(); if (!_zen) UpdateInspector(); break;
                case "inspector":
                    if (_workspace.Active?.OpenInspector is not null) HideInspector(_workspace.Active);
                    else if (App.Plugins.Plugins.OfType<Plugins.ITabPlugin>().FirstOrDefault(p => App.Plugins.IsEnabled(p.Metadata.Id) && p.Accessory.Placement == AccessoryPlacement.Inspector) is { } plugin)
                        ToggleInspector(plugin.Metadata.Id);
                    break;
                case "manageHosts": await ShowHostEditorAsync(); break;
                case "manageIdentities": await ShowIdentitiesAsync(); break;
                case "settings": SettingsWindow.ShowFor(App.Plugins); break;
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            await Alerts.ContentAsync("Unable to complete action", ex.Message, "Close", null, WorkspaceRoot.ActualTheme, _ => { });
        }
    }

    private async Task RunPluginCommandAsync(Func<Task> run)
    {
        try { await run(); }
        catch (OperationCanceledException) { }
        catch (Exception ex) { await Alerts.ContentAsync("Action Failed", ex.Message, "Close", null, WorkspaceRoot.ActualTheme, _ => { }); }
    }

    private async Task ShowHostEditorAsync()
    {
        _connecting = true;
        try { await HostManager.ShowAsync(WorkspaceRoot.ActualTheme, host => _workspace.AllPanes.Select(t => t.Model).FirstOrDefault(m =>
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
