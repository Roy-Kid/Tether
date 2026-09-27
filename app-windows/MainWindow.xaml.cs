using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Tether;
using TetherApp.Files;
using TetherApp.Plugins;

namespace TetherApp;

public sealed partial class MainWindow : Window
{
    private bool _refreshingTabs;
    private bool _revealPending;
    private bool _connecting;
    private Window? _hostPicker;
    private readonly Workspace _workspace = new();

    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBarDragArea);
        WorkspaceRoot.Loaded += (_, _) =>
        {
            UpdateTitleBar();
            WorkspaceRoot.XamlRoot.Changed += (_, _) => UpdateTitleBar();
        };
        WorkspaceRoot.ActualThemeChanged += (_, _) =>
        {
            UpdateTitleBar();
            ApplyTerminalPalette();
        };
        AppWindow.Changed += (_, e) =>
        {
            if (e.DidSizeChange || e.DidPresenterChange) UpdateTitleBar();
        };
        TabStrip.SizeChanged += (_, _) => QueueSelectedTabReveal();
        Closed += (_, _) => CompositionTarget.Rendering -= RevealSelectedTab;
        Closed += async (_, _) => await _workspace.DisposeAsync();
        BuildPluginButtons();
        App.Plugins.Changed += OnPluginsChanged;
        Closed += (_, _) => App.Plugins.Changed -= OnPluginsChanged;
#if DEBUG
        if (TryShowPreview()) return;
#endif
        AppSettings.Load();
        AppSettings.Changed += ApplyAppearance;
        Closed += (_, _) => AppSettings.Changed -= ApplyAppearance;
        ApplyAppearance();
        _workspace.Changed += () => DispatcherQueue.TryEnqueue(OnWorkspaceChanged);
        Content.KeyDown += OnKeyDown;
        // Activation hands focus back to the XAML island; the terminal's
        // input window is where typing goes.
        Activated += (_, e) =>
        {
            if (e.WindowActivationState != WindowActivationState.Deactivated)
            {
                if (!_connecting && _workspace.Active?.OpenInspector is null)
                    _workspace.Active?.Surface.FocusTerminal();
            }
        };
        _ = OpenFirstTabAsync();
    }

    private async Task OpenFirstTabAsync()
    {
        await _workspace.AddAsync();
    }

    private void ApplyAppearance()
    {
        WorkspaceRoot.RequestedTheme = Appearance.RequestedTheme;
        ApplyTerminalPalette();
        UpdateTitleBar();
    }

    private void ApplyTerminalPalette()
    {
        var palette = WorkspaceRoot.ActualTheme == ElementTheme.Dark ? Palette.Dark : Palette.Light;
        _workspace.CurrentPalette = palette;
        Appearance.SetCanvas(palette);
        foreach (var tab in _workspace.Tabs) tab.Surface.SetPalette(palette);
    }

    private void UpdateTitleBar()
    {
        var titleBar = AppWindow.TitleBar;
        var scale = WorkspaceRoot.XamlRoot?.RasterizationScale ?? 1;
        if (scale <= 0) scale = 1;
        // Insets are physical pixels. Writing a new value on every size
        // change — even the same one — lays the terminal out again, and at
        // 150% or 200% the height flutters by a pixel. The window shakes.
        SetInset(CaptionLeftInset, titleBar.LeftInset / scale);
        SetInset(CaptionRightInset, titleBar.RightInset / scale);
        var header = Math.Ceiling(titleBar.Height / scale) + 8;
        if (Math.Abs(WindowHeader.MinHeight - header) >= 1)
            WindowHeader.MinHeight = header;
        titleBar.ButtonBackgroundColor = Microsoft.UI.Colors.Transparent;
        titleBar.ButtonInactiveBackgroundColor = Microsoft.UI.Colors.Transparent;
        titleBar.ButtonHoverBackgroundColor = ThemeColor("SubtleFillColorSecondaryBrush");
        titleBar.ButtonPressedBackgroundColor = ThemeColor("SubtleFillColorTertiaryBrush");
        // Resolve in the window's theme, including the offline light/dark preview.
        var foreground = ((SolidColorBrush)HostName.Foreground).Color;
        titleBar.ButtonForegroundColor = foreground;
        titleBar.ButtonHoverForegroundColor = foreground;
        titleBar.ButtonInactiveForegroundColor = ((SolidColorBrush)StatusText.Foreground).Color;
    }

    /// <summary>Caption insets are physical pixels. Skip a write that does not change the DIP width, or the terminal is laid out again and shakes.</summary>
    private static void SetInset(ColumnDefinition column, double dips)
    {
        var next = new GridLength(Math.Max(0, dips));
        if (column.Width.GridUnitType == GridUnitType.Pixel && Math.Abs(column.Width.Value - next.Value) < 0.5)
            return;
        column.Width = next;
    }

    private static global::Windows.UI.Color ThemeColor(string key) =>
        Application.Current.Resources[key] is SolidColorBrush brush
            ? brush.Color
            : ((SolidColorBrush)Application.Current.Resources["ChromeSubtleBrush"]).Color;

    private void OnWorkspaceChanged()
    {
        _refreshingTabs = true;
        try
        {
            // Retain native tab containers and keyboard focus when selection changes.
            foreach (var removed in TabStrip.TabItems.OfType<TabViewItem>()
                .Where(item => item.Tag is Tab tab && !_workspace.Tabs.Contains(tab)).ToList())
                TabStrip.TabItems.Remove(removed);
            foreach (var tab in _workspace.Tabs)
            {
                var item = TabStrip.TabItems.OfType<TabViewItem>().FirstOrDefault(item => item.Tag == tab);
                if (item is null)
                {
                    item = CreateTab(tab.Title);
                    item.Tag = tab;
                    TabStrip.TabItems.Add(item);
                }
                ((TextBlock)item.Header).Text = tab.Title;
                AutomationProperties.SetName(item, tab.Title);
                ToolTipService.SetToolTip(item, tab.Title);
            }
            TabStrip.SelectedIndex = _workspace.ActiveIndex;
        }
        finally { _refreshingTabs = false; }
        var current = _workspace.Active;
        // A status/title refresh must not unload the active terminal and
        // hide its native child window. Reparent only when switching tabs.
        if (TerminalHostPlaceholder.Children.FirstOrDefault() != current?.Surface)
        {
            TerminalHostPlaceholder.Children.Clear();
            if (current is not null) TerminalHostPlaceholder.Children.Add(current.Surface);
        }
        if (current is not null)
        {
            Wire(current);
        }
        RefreshStatusBar();
        UpdateInspector();
    }

    private void BuildPluginButtons()
    {
        PluginButtons.Children.Clear();
        foreach (var plugin in App.Plugins.Plugins.OfType<ITabPlugin>()
            .Where(plugin => plugin.Accessory.Placement == AccessoryPlacement.Inspector && App.Plugins.IsEnabled(plugin.Metadata.Id)))
        {
            var button = new ToggleButton
            {
                Style = (Style)Application.Current.Resources["ChromeIconToggleStyle"],
                Content = plugin.Accessory.Glyph,
                IsChecked = _workspace.Active?.OpenInspector == plugin.Metadata.Id,
                Tag = plugin.Metadata.Id,
            };
            ToolTipService.SetToolTip(button, plugin.Accessory.Name);
            AutomationProperties.SetName(button, plugin.Accessory.Name);
            button.Click += (_, _) => ToggleInspector(plugin.Metadata.Id);
            PluginButtons.Children.Add(button);
        }
    }

    private void OnPluginsChanged()
    {
        foreach (var tab in _workspace.Tabs)
        {
            if (tab.OpenInspector is { } open && !App.Plugins.IsEnabled(open)) tab.OpenInspector = null;
        }
        BuildPluginButtons();
        _ = DetachDisabledAsync();
        UpdateInspector();
    }

    private async Task DetachDisabledAsync()
    {
        foreach (var tab in _workspace.Tabs)
        {
            foreach (var plugin in App.Plugins.Plugins.Where(plugin => !App.Plugins.IsEnabled(plugin.Metadata.Id)))
                await tab.DetachAsync(plugin.Metadata.Id);
        }
    }

    private void ToggleInspector(string id)
    {
#if DEBUG
        if (_preview)
        {
            BuildPluginButtons();
            return;
        }
#endif
        if (_workspace.Active is not { } tab) return;
        tab.OpenInspector = tab.OpenInspector == id ? null : id;
        BuildPluginButtons();
        UpdateInspector();
    }

    private void UpdateInspector()
    {
        InspectorHost.Child = null;
        var plugin = InspectorPlugin();
        var tab = _workspace.Active;
        var visible = plugin is not null && tab is not null;
        InspectorHost.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        if (!visible || tab is null || plugin is null) return;
        var attachment = tab.Attach(plugin, Context(tab, plugin));
        InspectorHost.Child = attachment.View;
        _ = attachment.ShownAsync();
    }

    private ITabPlugin? InspectorPlugin() =>
        _workspace.Active?.OpenInspector is not { } id ? null
        : App.Plugins.Plugins.OfType<ITabPlugin>().FirstOrDefault(plugin =>
            plugin.Metadata.Id == id && App.Plugins.IsEnabled(plugin.Metadata.Id)
            && plugin.Accessory.Placement == AccessoryPlacement.Inspector);

    private void HideInspector(Tab tab)
    {
        tab.OpenInspector = null;
        if (_workspace.Active == tab)
        {
            BuildPluginButtons();
            UpdateInspector();
        }
    }

    private TabContext Context(Tab tab, ITabPlugin plugin) => new()
    {
        Model = tab.Model,
        InsertText = text => tab.Model.Send(new TerminalInput.Paste(text)),
        WorkingDirectory = () => tab.Model.WorkingDirectory,
        Show = () =>
        {
            tab.OpenInspector = plugin.Metadata.Id;
            if (_workspace.Active == tab)
            {
                BuildPluginButtons();
                UpdateInspector();
            }
        },
        Dismiss = () => HideInspector(tab),
        WindowHandle = () => WinRT.Interop.WindowNative.GetWindowHandle(this),
        DialogRoot = () => WorkspaceRoot.XamlRoot,
        Overlay = tab.Surface.SetOverlayVisible,
    };

    private void Wire(Tab tab)
    {
        tab.Surface.QueryLink = link => QueryLinkAsync(tab, link);
        tab.Surface.TryOpenLink = link => TryOpenLink(tab, link);
        tab.Surface.LinkCommands = link => LinkCommands(tab, link);
        tab.Surface.ReceiveDrop = paths => ReceiveDropAsync(tab, paths);
    }

    private IEnumerable<ITabAttachment> Interested(Tab tab)
    {
        foreach (var plugin in App.Plugins.Plugins.OfType<ITabPlugin>())
        {
            if (!App.Plugins.IsEnabled(plugin.Metadata.Id)) continue;
            yield return tab.Attach(plugin, Context(tab, plugin));
        }
    }

    private async Task<bool?> QueryLinkAsync(Tab tab, TerminalLink link)
    {
        foreach (var attachment in Interested(tab))
        {
            if (attachment.ActionsFor(link)?.Exists is not { } exists) continue;
            return await exists(CancellationToken.None);
        }
        return null;
    }

    private bool TryOpenLink(Tab tab, TerminalLink link)
    {
        foreach (var attachment in Interested(tab))
        {
            if (attachment.ActionsFor(link)?.Open is not { } open) continue;
            _ = open(CancellationToken.None);
            return true;
        }
        return false;
    }

    private IReadOnlyList<(string Title, Action Run)> LinkCommands(Tab tab, TerminalLink link)
    {
        var commands = new List<(string, Action)>();
        foreach (var attachment in Interested(tab))
        {
            foreach (var command in attachment.ActionsFor(link)?.Commands ?? [])
            {
                var run = command.Run;
                commands.Add((command.Title, () => _ = run(CancellationToken.None)));
            }
        }
        return commands;
    }

    private async Task ReceiveDropAsync(Tab tab, IReadOnlyList<string> paths)
    {
        foreach (var attachment in Interested(tab))
        {
            if (attachment.Receive(paths)) return;
        }
        var style = FilesPaths.StyleFor(tab.Model.IsRemote, tab.Model.IsWsl, tab.Model.LocalProfile);
        if (style == QuoteStyle.Cmd && paths.Any(FilesPaths.CmdUnsafe)) return;
        tab.Model.Send(new TerminalInput.Paste(string.Join(" ", paths.Select(path => FilesPaths.Quote(path, style))) + " "));
    }

    private void InspectorResize_DragDelta(object sender, DragDeltaEventArgs e)
    {
        var minimum = (double)Application.Current.Resources["FilesPaneMinWidth"];
        InspectorHost.Width = Math.Clamp(InspectorHost.ActualWidth - e.HorizontalChange, minimum, Math.Max(minimum, WorkspaceRoot.ActualWidth * 0.7));
    }

    private TabViewItem CreateTab(string title)
    {
        var item = new TabViewItem
        {
            Header = new TextBlock
            {
                Text = title,
                FontSize = (double)Application.Current.Resources["TitleSize"],
                MaxWidth = (double)Application.Current.Resources["TabTitleWidth"],
                TextTrimming = TextTrimming.CharacterEllipsis,
            },
        };
        AutomationProperties.SetName(item, title);
        ToolTipService.SetToolTip(item, title);
        return item;
    }

    private void Tab_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        QueueSelectedTabReveal();
        if (!_refreshingTabs && TabStrip.SelectedItem is TabViewItem { Tag: Tab tab })
        {
            var index = _workspace.Tabs.ToList().IndexOf(tab);
            if (index >= 0 && index != _workspace.ActiveIndex) _workspace.Select(index);
        }
    }

    private void QueueSelectedTabReveal()
    {
        if (_revealPending) return;
        _revealPending = true;
        // Initial window sizing can invalidate a scroll request made during Loaded.
        CompositionTarget.Rendering += RevealSelectedTab;
    }

    private void RevealSelectedTab(object? sender, object e)
    {
        CompositionTarget.Rendering -= RevealSelectedTab;
        _revealPending = false;
        if (TabStrip.SelectedItem is TabViewItem selected)
            RevealTab(TabStrip, selected);
    }

    private static bool RevealTab(DependencyObject parent, TabViewItem selected)
    {
        if (parent is ListView list)
        {
            list.ScrollIntoView(selected);
            return true;
        }
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
            if (RevealTab(VisualTreeHelper.GetChild(parent, i), selected)) return true;
        return false;
    }

    private async void Tab_CloseRequested(TabView sender, TabViewTabCloseRequestedEventArgs e)
    {
        // WinUI raises this for the close button, middle click and Ctrl+F4.
#if DEBUG
        if (_preview) { TabStrip.TabItems.Remove(e.Tab); return; }
#endif
        if (e.Tab.Tag is not Tab tab) return;
        await CloseTabAsync(tab);
    }

    private async void Tab_AddRequested(TabView sender, object args)
    {
#if DEBUG
        if (_preview) { TabStrip.TabItems.Add(CreateTab("PowerShell")); return; }
#endif
        await _workspace.AddAsync();
    }

    private void RefreshStatusBar()
    {
        var model = _workspace.Active?.Model;
        HostName.Text = _workspace.Active?.Title ?? "Choose host";
        var bar = model?.Bar ?? RemoteBar.Idle();
        var live = bar.Phase == RemotePhase.Connected;
        StatusDot.Fill = (Brush)Application.Current.Resources[live ? "SuccessBrush" : "ChromeSubtleBrush"];
        StatusText.Text = live ? "" : bar.Status;
        var spoken = model?.LastError ?? model?.Status ?? "Not connected";
        ToolTipService.SetToolTip(StatusText, spoken);
        AutomationProperties.SetName(StatusText, spoken);
        ConnectProgress.IsActive = bar.ShowsProgress;
        ConnectProgress.Visibility = bar.ShowsProgress ? Visibility.Visible : Visibility.Collapsed;
        AuthMark.Visibility = bar.ShowsAuth ? Visibility.Visible : Visibility.Collapsed;
        CancelConnectButton.Visibility = bar.ShowsCancel ? Visibility.Visible : Visibility.Collapsed;
        ReconnectButton.Visibility = model?.CanReconnect == true ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetName(HostButton, "Host, " + HostName.Text);
        AutomationProperties.SetHelpText(HostButton, HostName.Text);
        ToolTipService.SetToolTip(HostButton, model?.LastError ?? HostName.Text);
    }

    private void Connect_Click(object sender, RoutedEventArgs e) => ShowHostPicker();

    /// <summary>
    /// A separate window, not a flyout. A flyout is painted in this window's
    /// XAML island, under the terminal's child HWND, and hiding that child
    /// to reveal it blanks the shell and shifts it.
    /// </summary>
    private void ShowHostPicker()
    {
        if (_hostPicker is not null)
        {
            _hostPicker.Close();
            return;
        }

        var query = new TextBox { PlaceholderText = "Find a host…" };
        var problem = new TextBlock
        {
            Text = "No matching hosts.",
            TextWrapping = TextWrapping.Wrap,
            Foreground = (Brush)Application.Current.Resources["ChromeSubtleBrush"],
            Visibility = Visibility.Collapsed,
        };
        var list = new ListView
        {
            MaxHeight = (double)Application.Current.Resources["PickerListHeight"],
            SelectionMode = ListViewSelectionMode.Single,
            IsItemClickEnabled = true,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
        };

        void Reload()
        {
            IReadOnlyList<HostEntry> all;
#if DEBUG
            if (_preview) all = PreviewHosts;
            else
#endif
            try { all = SshConfig.Load(); }
            catch (Exception ex)
            {
                problem.Text = ex.Message;
                problem.Visibility = Visibility.Visible;
                list.Items.Clear();
                list.Visibility = Visibility.Collapsed;
                return;
            }
            problem.Text = "No matching hosts.";
            list.Items.Clear();
            foreach (var host in SshConfig.Filter(all, query.Text))
                list.Items.Add(new HostRow(host));
            var any = list.Items.Count > 0;
            problem.Visibility = any ? Visibility.Collapsed : Visibility.Visible;
            list.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        }

        query.TextChanged += (_, _) => Reload();
        query.KeyDown += async (_, e) =>
        {
            if (e.Key is Windows.System.VirtualKey.Down or Windows.System.VirtualKey.Up)
            {
                if (list.Items.Count > 0)
                {
                    var step = e.Key == Windows.System.VirtualKey.Down ? 1 : -1;
                    list.SelectedIndex = Math.Clamp(list.SelectedIndex + step, 0, list.Items.Count - 1);
                    list.ScrollIntoView(list.SelectedItem);
                }
                e.Handled = true;
            }
            else if (e.Key == Windows.System.VirtualKey.Enter && RowHost(list.SelectedItem) is { } selected)
            {
                e.Handled = true;
                await ChooseHostAsync(selected);
            }
        };
        list.ItemClick += async (_, e) =>
        {
            if (RowHost(e.ClickedItem) is { } host) await ChooseHostAsync(host);
        };
        list.Tapped += async (_, _) =>
        {
            if (RowHost(list.SelectedItem) is { } host) await ChooseHostAsync(host);
        };

        var panel = new StackPanel { Spacing = 8, Padding = new Thickness(12) };
        panel.Children.Add(query);
        panel.Children.Add(problem);
        panel.Children.Add(list);

        var window = new Window { Title = "Hosts", Content = panel };
        var presenter = Microsoft.UI.Windowing.OverlappedPresenter.CreateForDialog();
        presenter.SetBorderAndTitleBar(true, false);
        presenter.IsResizable = false;
        presenter.IsMinimizable = false;
        presenter.IsMaximizable = false;
        window.AppWindow.SetPresenter(presenter);
        const int width = 320, height = 420;
        window.AppWindow.Resize(new Windows.Graphics.SizeInt32(width, height));
        WindowPlacement.Above(this, HostButton, window, width, height);
        WindowPlacement.Own(window);
        window.Closed += (_, _) => { if (_hostPicker == window) _hostPicker = null; };
        _hostPicker = window;
        Reload();
        window.Activate();
        query.Focus(FocusState.Programmatic);
    }

    /// <summary>The row a click lands on. A <see cref="ListView"/> wraps whatever was added, so the host is not the clicked object itself.</summary>
    private static HostEntry? RowHost(object? item) => item switch
    {
        HostRow row => row.Host,
        ListViewItem { Content: HostRow row } => row.Host,
        _ => null,
    };

    private sealed class HostRow(HostEntry host)
    {
        public HostEntry Host { get; } = host;
        public override string ToString() => host.Label;
    }

    private async Task ChooseHostAsync(HostEntry host)
    {
        _hostPicker?.Close();
#if DEBUG
        if (_preview) { HostName.Text = host.Label; return; }
#endif
        await OpenHostAsync(host);
    }

    private async Task OpenHostAsync(HostEntry host)
    {
        if (_workspace.Active is not { } tab) return;

        tab.Title = host.Alias;
        tab.Model.Keep(host);
        OnWorkspaceChanged();

        if (host.JumpError is { } problem)
        {
            tab.Model.Fail(problem);
            OnWorkspaceChanged();
            return;
        }

        var plan = RemoteLink.Plan(host, Environment.UserName);
        tab.Model.Begin(host);
        OnWorkspaceChanged();

        // A live ControlMaster already spent the verification code. The alias
        // is what `ssh -O check` is keyed on, not the resolved hostname.
        // A master that then fails to attach is a failed attach, not a reason
        // to start a second login and ask for the code again.
        _connecting = true;
        var mastered = false;
        try
        {
            if (await TerminalSession.SshMasterRunningAsync(host.Alias))
            {
                mastered = true;
                await tab.Model.AttachMasterAsync(host.Alias);
            }
        }
        finally
        {
            if (mastered || tab.Model.IsLive)
            {
                _connecting = false;
                OnWorkspaceChanged();
                if (_workspace.Active == tab && tab.Model.IsLive && tab.OpenInspector is null)
                    tab.Surface.FocusTerminal();
            }
        }
        if (mastered || tab.Model.IsLive) return;

        var prompter = new SessionModel.PromptDialog(Content.XamlRoot, tab.Model);
        var destination = new Destination(plan.Host, plan.Port, plan.User);
        // Don't focus the shell while a trust or password window is up; that
        // dismisses it. The shell itself stays on screen.
        try
        {
            // An `IdentityFile` in the ssh config is already a credential, so a
            // password is not required to start the handshake — the same thing
            // `ssh host` does (HostStore.swift). Each hop logs in as itself.
            var secrets = Credentials(plan.IdentityFile, prompter);
            var jumps = plan.Hops.Select(hop => new Tether.Jump(
                hop.HostName,
                hop.Port,
                hop.User ?? Environment.UserName,
                Credentials(hop.IdentityFile, prompter))).ToArray();
            await tab.Model.ConnectAsync(Content.XamlRoot, destination, secrets, jumps);
        }
        catch (IOException ex)
        {
            tab.Model.Fail(ex.Message);
        }
        finally
        {
            _connecting = false;
        }
        OnWorkspaceChanged();
        // A late success must not pull the keyboard back if this tab is no longer the one on screen.
        if (_workspace.Active == tab && tab.Model.IsLive && tab.OpenInspector is null)
            tab.Surface.FocusTerminal();
    }

    /// <summary>
    /// A configured key, then a prompt. The prompt is how a hop that wants a
    /// passphrase can ask; the destination's password is not sent along.
    /// </summary>
    private static Secret[] Credentials(string? identityFile, SessionModel.PromptDialog prompter)
    {
        if (identityFile is not { Length: > 0 } key) return [new Secret.Interactive(prompter)];
        var path = SshConfig.ExpandHome(key);
        if (!File.Exists(path))
            throw new IOException($"Could not read the key at {key}.");
        return [new Secret.PrivateKey(File.ReadAllText(path)), new Secret.Interactive(prompter)];
    }

    private void CancelConnect_Click(object sender, RoutedEventArgs e) =>
        _workspace.Active?.Model.CancelDial();

    private async void Reconnect_Click(object sender, RoutedEventArgs e)
    {
        var model = _workspace.Active?.Model;
        if (model?.RemoteHost is not { } host || !model.CanReconnect) return;
        await OpenHostAsync(host);
    }

    private void Settings_Click(object sender, RoutedEventArgs e)
    {
#if DEBUG
        if (_preview) return;
#endif
        // The same control as on macOS: it opens preferences. A window with
        // a sidebar is the Windows shape of `NavigationSplitView`.
        _ = new SettingsWindow(App.Plugins);
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var control = InputKeyboardSource
            .GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

        if (control && e.Key == Windows.System.VirtualKey.N)
        {
            _ = _workspace.AddAsync();
            e.Handled = true;
            return;
        }
        if (control && e.Key == Windows.System.VirtualKey.W)
        {
            _ = CloseSelectedAsync();
            e.Handled = true;
        }
    }

    private async Task CloseSelectedAsync()
    {
        if (_workspace.Active is { } tab) await CloseTabAsync(tab);
    }

    private async Task CloseTabAsync(Tab tab)
    {
        var index = _workspace.Tabs.ToList().IndexOf(tab);
        if (index < 0) return;
        var note = tab.Attachments.Select(attachment => attachment.CloseNote).FirstOrDefault(note => note is not null);
        if (note is not null)
        {
            var dialog = new ContentDialog
            {
                XamlRoot = WorkspaceRoot.XamlRoot,
                RequestedTheme = WorkspaceRoot.ActualTheme,
                Title = "Close this tab?",
                Content = note,
                PrimaryButtonText = "Close",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        }
        await _workspace.CloseAsync(index);
        if (_workspace.Tabs.Count == 0) Close();
    }
}
