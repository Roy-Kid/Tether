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
    private TrayHost? _tray;
    private bool _refreshingTabs;
    private bool _revealPending;
    private bool _connecting;
    private bool _splitting;
    private readonly HashSet<TerminalPane> _wiredPanes = [];
    private readonly Dictionary<Tab, SplitTerminalView> _splitViews = [];
    private Window? _hostPicker;
    private readonly Workspace _workspace = new();

    public MainWindow()
    {
        InitializeComponent();
        AppBranding.Apply(this);
        SystemBackdrop = new MicaBackdrop { Kind = Microsoft.UI.Composition.SystemBackdrops.MicaKind.BaseAlt };
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
        AppWindow.Closing += (sender, e) =>
        {
            if (_windowCloseApproved || _tray is null) return;
            e.Cancel = true;
            AppWindow.Hide();
        };
        Closed += (_, _) => _tray?.Dispose();
        Closed += async (_, _) => await _workspace.DisposeAsync();
        BuildPluginButtons();
        App.Plugins.Changed += OnPluginsChanged;
        Closed += (_, _) => App.Plugins.Changed -= OnPluginsChanged;
#if DEBUG
        if (TryShowPreview()) return;
#endif
        _tray = new TrayHost(
            () => DispatcherQueue.TryEnqueue(ShowFromBackground),
            () => DispatcherQueue.TryEnqueue(() => _ = QuitAsync()));
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
        if (App.CommandLineValue("--open-plugin") is { } id && App.Plugins.Plugins.Any(p => p.Metadata.Id == id) && App.Plugins.IsEnabled(id))
            ToggleInspector(id);
    }

    private void ApplyAppearance()
    {
        WorkspaceRoot.RequestedTheme = Appearance.RequestedTheme;
        ApplyTerminalPalette();
        UpdateTitleBar();
        ApplyWorkspaceVisibility();
    }

    private void ApplyTerminalPalette()
    {
        var palette = TerminalAppearance.Choose(WorkspaceRoot.ActualTheme == ElementTheme.Dark);
        _workspace.CurrentPalette = palette;
        Appearance.SetCanvas(palette);
        foreach (var tab in _workspace.AllPanes) tab.Surface.SetPalette(palette);
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
                .Where(item => item.Tag switch
                {
                    Tab tab => !_workspace.VisibleTabs.Contains(tab),
                    ExtensionTab extension => !_workspace.VisibleExtensions.Contains(extension),
                    _ => true,
                }).ToList())
                TabStrip.TabItems.Remove(removed);
            foreach (var tab in _workspace.VisibleTabs)
            {
                var item = TabStrip.TabItems.OfType<TabViewItem>().FirstOrDefault(item => item.Tag == tab);
                if (item is null)
                {
                    item = CreateTab(tab.Title);
                    item.Tag = tab;
                    TabStrip.TabItems.Add(item);
                }
                ((WorkspaceTabHeader)item.Header).Update(tab);
                AutomationProperties.SetName(item, tab.Title);
                ToolTipService.SetToolTip(item, tab.Title);
            }
            foreach (var extension in _workspace.VisibleExtensions)
            {
                var item = TabStrip.TabItems.OfType<TabViewItem>().FirstOrDefault(item => item.Tag == extension);
                if (item is null)
                {
                    item = CreateExtensionTab(extension);
                    TabStrip.TabItems.Add(item);
                }
                else if (item.Header is WorkspaceTabHeader header) header.UpdateExtension(extension);
                AutomationProperties.SetName(item, extension.Title);
                ToolTipService.SetToolTip(item, extension.Title);
            }
            if (_workspace.ActiveExtension is { } activeExtension)
                TabStrip.SelectedItem = TabStrip.TabItems.OfType<TabViewItem>().FirstOrDefault(i => i.Tag == activeExtension);
            else TabStrip.SelectedIndex = _workspace.ActiveIndex;
            RefreshVerticalTabs();
        }
        finally { _refreshingTabs = false; }
        var current = _workspace.Active;
        // A status/title refresh must not unload the active terminal and
        // hide its native child window. Reparent only when switching tabs.
        if (_workspace.ActiveExtension is { } openExtension)
        {
            if (TerminalHostPlaceholder.Children.FirstOrDefault() != openExtension.View)
            {
                TerminalHostPlaceholder.Children.Clear();
                TerminalHostPlaceholder.Children.Add(openExtension.View);
            }
            _ = RunPluginCommandAsync(openExtension.Attachment.ShownAsync);
        }
        else if (_workspace.ActiveGroup is { } group)
        {
            if (!_splitViews.TryGetValue(group, out var view)) _splitViews[group] = view = new SplitTerminalView(group, _workspace);
            view.Update();
            if (TerminalHostPlaceholder.Children.FirstOrDefault() != view)
            {
                TerminalHostPlaceholder.Children.Clear();
                TerminalHostPlaceholder.Children.Add(view);
            }
            foreach (var pane in group.Panes) Wire(pane);
        }
        else TerminalHostPlaceholder.Children.Clear();
        EmptyWorkspace.Visibility = current is null && _workspace.ActiveExtension is null ? Visibility.Visible : Visibility.Collapsed;
        foreach (var removed in _splitViews.Keys.Where(t => !_workspace.Tabs.Contains(t)).ToArray()) _splitViews.Remove(removed);
        _wiredPanes.RemoveWhere(pane => !_workspace.Contains(pane));
        _workspace.Persist();
        UpdateSplitButtons();
        RefreshStatusBar();
        ApplyWorkspaceVisibility();
        UpdateInspector();
    }

    private readonly Dictionary<string, (Button Button, Flyout Flyout)> _popovers = new();

    private void BuildPluginButtons()
    {
        PluginButtons.Children.Clear();
        _popovers.Clear();
        foreach (var plugin in App.Plugins.Plugins.OfType<ITabPlugin>().Where(plugin => App.Plugins.IsEnabled(plugin.Metadata.Id)))
        {
            if (plugin.Accessory.Placement == AccessoryPlacement.Inspector)
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
            else
            {
                var button = new Button
                {
                    Style = (Style)Application.Current.Resources["ChromeIconButtonStyle"],
                    Content = plugin.Accessory.Glyph,
                };
                var flyout = new Flyout { Placement = FlyoutPlacementMode.TopEdgeAlignedLeft };
                flyout.Closed += (_, _) => { flyout.Content = null; };
                ToolTipService.SetToolTip(button, plugin.Accessory.Name);
                AutomationProperties.SetName(button, plugin.Accessory.Name);
                button.Click += (_, _) => ShowPopover(plugin, button, flyout);
                _popovers[plugin.Metadata.Id] = (button, flyout);
                PluginButtons.Children.Add(button);
            }
        }
    }

    private void ShowPopover(ITabPlugin plugin, Button button, Flyout flyout)
    {
#if DEBUG
        if (_preview) return;
#endif
        if (_workspace.Active is not { } tab) return;
        var context = Context(tab, plugin);
        context = context with { Dismiss = () => flyout.Hide() };
        var attachment = tab.Attach(plugin, context);
        if (attachment is TmuxAttachment tmux) tmux.UseDismiss(() => flyout.Hide());
        flyout.Content = null;
        flyout.Content = attachment.View;
        flyout.ShowAt(button);
        _ = attachment.ShownAsync();
    }

    private void OnPluginsChanged()
    {
        foreach (var tab in _workspace.AllPanes)
        {
            if (tab.OpenInspector is { } open && !App.Plugins.IsEnabled(open)) tab.OpenInspector = null;
        }
        BuildPluginButtons();
        _ = DetachDisabledAsync();
        _ = CloseMissingExtensionsAsync();
        UpdateInspector();
    }

    private async Task CloseMissingExtensionsAsync()
    {
        var known = App.Plugins.Plugins.Select(p => p.Metadata.Id).ToHashSet();
        foreach (var extension in _workspace.Extensions.Where(e => !known.Contains(e.PluginId)).ToArray())
            await CloseExtensionAsync(extension);
    }

    private async Task DetachDisabledAsync()
    {
        foreach (var tab in _workspace.AllPanes)
        {
            foreach (var plugin in App.Plugins.Plugins.Where(plugin => !App.Plugins.IsEnabled(plugin.Metadata.Id)))
                await tab.DetachAsync(plugin.Metadata.Id);
        }
        foreach (var plugin in App.Plugins.Plugins.Where(plugin => !App.Plugins.IsEnabled(plugin.Metadata.Id)))
            await _workspace.CloseExtensionsForPluginAsync(plugin.Metadata.Id);
    }

    /// <summary>
    /// Opens a plugin as a full workspace tab (macOS <c>PluginWorkspace</c>).
    /// Web panels and other inspector plugins can stand in for a terminal tab.
    /// </summary>
    private void OpenExtensionTab(string id)
    {
        if (App.Plugins.Plugins.OfType<ITabPlugin>().FirstOrDefault(p => p.Metadata.Id == id && App.Plugins.IsEnabled(id))
            is not { } plugin) return;
        if (_workspace.VisibleExtensions.FirstOrDefault(e => e.PluginId == id) is { } existing)
        {
            _workspace.Activate(existing);
            return;
        }
        var model = new SessionModel();
        if (_workspace.CurrentHost is { } host) model.Keep(host);
        var attachment = plugin.Attach(new TabContext
        {
            Model = model,
            InsertText = _ => { },
            WorkingDirectory = () => model.WorkingDirectory,
            Show = () => { },
            Dismiss = () =>
            {
                if (_workspace.Extensions.FirstOrDefault(e => e.PluginId == id) is { } open)
                    _ = CloseExtensionAsync(open);
            },
            WindowHandle = () => WinRT.Interop.WindowNative.GetWindowHandle(this),
            DialogRoot = () => WorkspaceRoot.XamlRoot,
            Overlay = _ => { },
        });
        _workspace.OpenExtension(plugin, attachment, _workspace.CurrentHost);
    }

    private async Task CloseExtensionAsync(ExtensionTab extension)
    {
        await _workspace.CloseExtensionAsync(extension);
        if (_workspace.Tabs.Count == 0 && _workspace.Extensions.Count == 0 && AppSettings.Current.CloseLastTab == "quit")
        {
            _windowCloseApproved = true;
            Close();
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
        // Without a live terminal, open the plugin as a workspace tab instead.
        if (_workspace.Active is not { } tab)
        {
            OpenExtensionTab(id);
            return;
        }
        tab.OpenInspector = tab.OpenInspector == id ? null : id;
        BuildPluginButtons();
        UpdateInspector();
    }

    private void UpdateInspector()
    {
        if (_zen) { InspectorHost.Visibility = Visibility.Collapsed; return; }
        var plugin = InspectorPlugin();
        var tab = _workspace.Active;
        var visible = plugin is not null && tab is not null;
        InspectorHost.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        if (!visible || tab is null || plugin is null) { InspectorHost.Child = null; return; }
        var attachment = tab.Attach(plugin, Context(tab, plugin));
        if (InspectorHost.Child == attachment.View) return;
        InspectorHost.Child = attachment.View;
        _ = RunPluginCommandAsync(attachment.ShownAsync);
    }

    private ITabPlugin? InspectorPlugin() =>
        _workspace.Active?.OpenInspector is not { } id ? null
        : App.Plugins.Plugins.OfType<ITabPlugin>().FirstOrDefault(plugin =>
            plugin.Metadata.Id == id && App.Plugins.IsEnabled(plugin.Metadata.Id)
            && plugin.Accessory.Placement == AccessoryPlacement.Inspector);

    private void HideInspector(TerminalPane tab)
    {
        tab.OpenInspector = null;
        if (_workspace.Active == tab)
        {
            BuildPluginButtons();
            UpdateInspector();
        }
    }

    private TabContext Context(TerminalPane tab, ITabPlugin plugin) => new()
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
        HostLabel = tab.Model.RemoteHost?.Label ?? "localhost",
        ShellLabel = string.IsNullOrWhiteSpace(tab.Title) ? "Shell" : tab.Title,
        Shells = () => _workspace.AllPanes.Select(pane => new ShellChoice(pane.Id, pane.Title, pane == _workspace.Active)).ToArray(),
        OpenShell = id =>
        {
            var pane = _workspace.AllPanes.FirstOrDefault(item => item.Id == id);
            if (pane is null) return;
            var index = _workspace.Tabs.ToList().FindIndex(group => group.Panes.Contains(pane));
            if (index >= 0) _workspace.Select(index);
            _workspace.Focus(pane);
        },
        NewShell = () => _ = _workspace.AddAsync(),
        WindowHandle = () => WinRT.Interop.WindowNative.GetWindowHandle(this),
        DialogRoot = () => WorkspaceRoot.XamlRoot,
        Overlay = visible => { foreach (var pane in _workspace.AllPanes) pane.Surface.SetOverlayVisible(visible); },
        OpenWebViewer = OpenWebViewerAsync,
    };

    private async Task<bool> OpenWebViewerAsync(string suffix, byte[] bytes, string fileName, CancellationToken token)
    {
        var matches = WebPluginCatalog.ViewersFor(App.Plugins, suffix);
        if (matches.Count == 0) return false;
        var plugin = matches[0].Plugin;
        token.ThrowIfCancellationRequested();
        if (await Alerts.ContentAsync(plugin.Metadata.Name, "document.read\n" + fileName, "Allow", null,
            WorkspaceRoot.ActualTheme, _ => { }) != ContentDialogResult.Primary) return false;
        token.ThrowIfCancellationRequested();
        // Prefer an already-open extension tab for this plugin on this host.
        ExtensionTab extension;
        if (_workspace.VisibleExtensions.FirstOrDefault(e => e.PluginId == plugin.Metadata.Id) is { } existing)
        {
            extension = existing;
            _workspace.Activate(extension);
        }
        else
        {
            var model = new SessionModel();
            if (_workspace.CurrentHost is { } host) model.Keep(host);
            var attachment = plugin.Attach(new TabContext
            {
                Model = model,
                InsertText = _ => { },
                WorkingDirectory = () => model.WorkingDirectory,
                Show = () => { },
                Dismiss = () =>
                {
                    if (_workspace.Extensions.FirstOrDefault(e => e.PluginId == plugin.Metadata.Id) is { } open)
                        _ = CloseExtensionAsync(open);
                },
                WindowHandle = () => WinRT.Interop.WindowNative.GetWindowHandle(this),
                DialogRoot = () => WorkspaceRoot.XamlRoot,
                Overlay = _ => { },
            });
            extension = _workspace.OpenExtension(plugin, attachment, _workspace.CurrentHost);
            extension.Title = plugin.Metadata.Name + " · " + fileName;
        }
        if (extension.Attachment is not WebAttachment web) return false;
        web.GrantDocument(bytes, fileName);
        _ = RunPluginCommandAsync(web.ShownAsync);
        return true;
    }

    private void Wire(TerminalPane tab)
    {
        if (_wiredPanes.Add(tab)) tab.Surface.SizeChanged += (_, _) => UpdateSplitButtons();
        tab.Surface.WorkspaceShortcut = HandleWorkspaceShortcut;
        tab.Surface.WantsFocus = () => _workspace.Active == tab;
        tab.Surface.TerminalFocused = () => _workspace.Focus(tab);
        tab.Surface.QueryLink = link => QueryLinkAsync(tab, link);
        tab.Surface.TryOpenLink = link => TryOpenLink(tab, link);
        tab.Surface.LinkCommands = link => LinkCommands(tab, link);
        tab.Surface.ReceiveDrop = paths => ReceiveDropAsync(tab, paths);
    }

    private IEnumerable<ITabAttachment> Interested(TerminalPane tab)
    {
        foreach (var plugin in App.Plugins.Plugins.OfType<ITabPlugin>())
        {
            if (!App.Plugins.IsEnabled(plugin.Metadata.Id)) continue;
            yield return tab.Attach(plugin, Context(tab, plugin));
        }
    }

    private async Task<bool?> QueryLinkAsync(TerminalPane tab, TerminalLink link)
    {
        foreach (var attachment in Interested(tab))
        {
            if (attachment.ActionsFor(link)?.Exists is not { } exists) continue;
            return await exists(CancellationToken.None);
        }
        return null;
    }

    private bool TryOpenLink(TerminalPane tab, TerminalLink link)
    {
        foreach (var attachment in Interested(tab))
        {
            if (attachment.ActionsFor(link)?.Open is not { } open) continue;
            _ = open(CancellationToken.None);
            return true;
        }
        return false;
    }

    private IReadOnlyList<(string Title, Action Run)> LinkCommands(TerminalPane tab, TerminalLink link)
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

    private async Task ReceiveDropAsync(TerminalPane tab, IReadOnlyList<string> paths)
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
        var header = new WorkspaceTabHeader(title);
        var item = new TabViewItem { Header = header };
        AutomationProperties.SetName(item, title);
        ToolTipService.SetToolTip(item, title);
        header.More.Click += (_, e) =>
        {
            if (item.Tag is Tab group) ShowTabMenu(header, group);
        };
        var selectedBeforePress = false;
        item.PointerPressed += (_, e) =>
        {
            selectedBeforePress = ReferenceEquals(TabStrip.SelectedItem, item);
            if (e.GetCurrentPoint(item).Properties.IsMiddleButtonPressed && item.Tag is Tab group)
            {
                e.Handled = true;
                _ = CloseTabAsync(group);
            }
        };
        item.Tapped += (_, e) =>
        {
            if (!selectedBeforePress || item.Tag is not Tab group) return;
            for (var parent = e.OriginalSource as DependencyObject; parent is not null; parent = VisualTreeHelper.GetParent(parent))
                if (parent is Button) return;
            ShowTabMenu(header, group);
        };
        item.RightTapped += (_, e) =>
        {
            if (item.Tag is Tab group) { e.Handled = true; ShowTabMenu(header, group); }
        };
        return item;
    }

    private TabViewItem CreateExtensionTab(ExtensionTab extension)
    {
        var header = new WorkspaceTabHeader(extension.Title);
        header.UpdateExtension(extension);
        var item = new TabViewItem { Header = header, Tag = extension };
        AutomationProperties.SetName(item, extension.Title);
        ToolTipService.SetToolTip(item, extension.Title);
        header.More.Visibility = Visibility.Collapsed;
        item.PointerPressed += (_, e) =>
        {
            if (e.GetCurrentPoint(item).Properties.IsMiddleButtonPressed && item.Tag is ExtensionTab open)
            {
                e.Handled = true;
                _ = CloseExtensionAsync(open);
            }
        };
        item.RightTapped += (_, e) =>
        {
            if (item.Tag is not ExtensionTab open) return;
            e.Handled = true;
            ShowMenu(header, [
                new("Close", () => _ = CloseExtensionAsync(open)),
            ]);
        };
        return item;
    }

    private void Tab_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        QueueSelectedTabReveal();
        if (_refreshingTabs || TabStrip.SelectedItem is not TabViewItem selected) return;
        if (selected.Tag is ExtensionTab extension)
        {
            if (!ReferenceEquals(_workspace.ActiveExtension, extension)) _workspace.Activate(extension);
            return;
        }
        if (selected.Tag is Tab tab)
        {
            var index = _workspace.VisibleTabs.ToList().IndexOf(tab);
            if (index >= 0 && (index != _workspace.ActiveIndex || _workspace.ActiveExtension is not null))
                _workspace.Select(index);
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
        if (e.Tab.Tag is ExtensionTab extension) await CloseExtensionAsync(extension);
        else if (e.Tab.Tag is Tab tab) await CloseTabAsync(tab);
    }

    private async void Tab_AddRequested(TabView sender, object args)
    {
#if DEBUG
        if (_preview) { TabStrip.TabItems.Add(CreateTab("PowerShell")); return; }
#endif
        await RunCommandAsync("newTab");
    }

    private void RefreshStatusBar()
    {
        var model = _workspace.Active?.Model;
        HostName.Text = _workspace.CurrentHostLabel;
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
        ToolTipService.SetToolTip(ReconnectButton, model?.RemoteHost is null ? "Restart" : "Reconnect");
        AutomationProperties.SetName(HostButton, "Host, " + HostName.Text);
        AutomationProperties.SetHelpText(HostButton, HostName.Text);
        var historyProblem = _workspace.HistoryProblem ?? model?.History?.Error;
        ToolTipService.SetToolTip(HostButton, model?.LastError ?? historyProblem ?? HostName.Text);
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
            var matches = SshConfig.Filter(all, query.Text).ToList();
            var connected = matches.Where(IsConnectedHost).ToList();
            if (_workspace.CurrentHost is { } current && matches.Any(h => h.Alias == current.Alias))
                connected = [current, .. connected.Where(h => h.Alias != current.Alias)];
            var connectedAliases = connected.Select(h => h.Alias).ToHashSet();
            var idle = matches.Where(h => !connectedAliases.Contains(h.Alias)).ToList();
            var localMatch = "localhost".Contains(query.Text.Trim(), StringComparison.OrdinalIgnoreCase);
            if (localMatch && _workspace.CurrentHost is null)
                list.Items.Add(new HostRow(null, connected: _workspace.AllPanes.Any(p => p.Model.IsLive && p.Model.RemoteHost is null)));
            foreach (var host in connected) list.Items.Add(new HostRow(host, connected: true));
            if (connected.Count > 0 && (idle.Count > 0 || (localMatch && _workspace.CurrentHost is not null)))
                list.Items.Add(new HostRow(null, separator: true));
            if (localMatch && _workspace.CurrentHost is not null)
                list.Items.Add(new HostRow(null));
            foreach (var host in idle) list.Items.Add(new HostRow(host));
            var any = list.Items.OfType<HostRow>().Any(r => !r.Separator);
            list.SelectedIndex = any ? 0 : -1;
            problem.Visibility = any ? Visibility.Collapsed : Visibility.Visible;
            list.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        }

        query.TextChanged += (_, _) => Reload();
        query.KeyDown += async (_, e) =>
        {
            var control = InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control)
                .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; _hostPicker?.Close(); return; }
            if (control && e.Key >= Windows.System.VirtualKey.Number1 && e.Key <= Windows.System.VirtualKey.Number9)
            {
                var index = (int)e.Key - (int)Windows.System.VirtualKey.Number1;
                if (index < list.Items.Count && RowHost(list.Items[index]) is { } numbered) { e.Handled = true; await ChooseHostAsync(numbered.Host); }
                return;
            }
            if (e.Key is Windows.System.VirtualKey.Down or Windows.System.VirtualKey.Up)
            {
                if (list.Items.Count > 0)
                {
                    var step = e.Key == Windows.System.VirtualKey.Down ? 1 : -1;
                    var next = list.SelectedIndex + step;
                    while (next >= 0 && next < list.Items.Count && list.Items[next] is HostRow { Separator: true }) next += step;
                    if (next >= 0 && next < list.Items.Count)
                    {
                        list.SelectedIndex = next;
                        list.ScrollIntoView(list.SelectedItem);
                    }
                }
                e.Handled = true;
            }
            else if (e.Key == Windows.System.VirtualKey.Enter && RowHost(list.SelectedItem) is { } selected)
            {
                e.Handled = true;
                await ChooseHostAsync(selected.Host);
            }
        };
        list.ItemClick += async (_, e) =>
        {
            if (RowHost(e.ClickedItem) is { } host) await ChooseHostAsync(host.Host);
        };


        var panel = new StackPanel { Spacing = 8, Padding = new Thickness(12), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        var searchRow = new Grid { ColumnSpacing = 8 };
        searchRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        searchRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        searchRow.Children.Add(query);
        var manage = EditorDialog.Icon("\uE70F", "Manage Hosts", () => { _hostPicker?.Close(); _ = RunCommandAsync("manageHosts"); });
        Grid.SetColumn(manage, 1); searchRow.Children.Add(manage); panel.Children.Add(searchRow);
        panel.Children.Add(problem);
        panel.Children.Add(list);

        var window = new Window { Title = "Hosts", Content = panel };
        AppBranding.Apply(window);
        window.SystemBackdrop = new DesktopAcrylicBackdrop();
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
    private static HostRow? RowHost(object? item) => item switch
    {
        HostRow { Separator: true } => null,
        HostRow row => row,
        ListViewItem { Content: HostRow { Separator: true } } => null,
        ListViewItem { Content: HostRow row } => row,
        _ => null,
    };

    private static void RememberRecentHost(HostEntry? host)
    {
        var alias = host?.Alias ?? "local";
        var recent = AppSettings.Current.RecentHosts.Where(a => a != alias).Prepend(alias).Take(8).ToArray();
        (AppSettings.Current with { RecentHosts = recent }).Save();
    }

    private bool IsConnectedHost(HostEntry host) =>
        _workspace.AllPanes.Any(pane => pane.Model.IsLive && pane.Model.RemoteHost is { } current &&
            IdentityStore.EndpointDigest(current) == IdentityStore.EndpointDigest(host));

    private sealed class HostRow(HostEntry? host, bool connected = false, bool separator = false)
    {
        public HostEntry? Host { get; } = host;
        public bool Separator { get; } = separator;
        public override string ToString() => Separator ? "────────" : (Host?.Label ?? "localhost") + (connected ? "  · connected" : "");
    }

    private readonly Dictionary<string, Task> _hostRequests = new();

    private Task ChooseHostAsync(HostEntry? host)
    {
        _hostPicker?.Close();
#if DEBUG
        if (_preview) { HostName.Text = host?.Label ?? "localhost"; return Task.CompletedTask; }
#endif
        var key = host is null ? "local" : host.Alias + IdentityStore.EndpointDigest(host);
        if (_hostRequests.TryGetValue(key, out var pending)) return pending;
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _hostRequests[key] = completion.Task;
        _ = ChooseHostCoreAsync(host, key, completion);
        return completion.Task;
    }

    private async Task ChooseHostCoreAsync(HostEntry? host, string key, TaskCompletionSource completion)
    {
        try
        {
            RememberRecentHost(host);
            _workspace.SelectHost(host);
            if (_workspace.VisibleTabs.Count == 0) await _workspace.AddAsync(ConnectPaneAsync);
            if (_workspace.CurrentHost == host) _workspace.Active?.Surface.FocusTerminal();
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            await Alerts.ContentAsync(host?.Label ?? "localhost", ex.Message, "Close", null,
                WorkspaceRoot.ActualTheme, _ => { });
        }
        finally { _hostRequests.Remove(key); completion.TrySetResult(); }
    }

    private async Task OpenHostAsync(HostEntry host, TerminalPane? target = null)
    {
        if ((target ?? _workspace.Active) is not { } tab) return;
        tab.Title = host.Alias;
        tab.Model.Keep(host);
        if (host.JumpError is { } problem) { tab.Model.Fail(problem); return; }
        if (host.Unsupported.Count > 0)
        {
            tab.Model.Fail("This host requires unsupported OpenSSH settings: " + string.Join(", ", host.Unsupported));
            return;
        }
        var plan = RemoteLink.Plan(host, Environment.UserName);
        tab.Model.Begin(host);
        var dial = tab.Model.DialToken;
        var generation = tab.Model.Generation;
        _connecting = true;
        try
        {
            var store = IdentityStore.Current;
            var identity = store.ForHost(host);
            var hops = plan.Hops.Select(h => (Hop: h, Host: IdentityAuthentication.HopHost(h))).ToArray();
            // Reusing OpenSSH cannot silently substitute a different managed identity.
            if (identity is null && hops.All(h => store.ForHost(h.Host) is null) && await TerminalSession.SshMasterRunningAsync(host.Alias))
            {
                await tab.Model.AttachMasterAsync(host.Alias);
                return;
            }
            tab.Model.NoteAsking();
            var prompter = new SessionModel.PromptDialog(Content.XamlRoot, tab.Model);
            async Task<bool> ConfirmIdentity(AccountIdentity account, HostEntry endpoint)
            {
                var result = await Alerts.ContentAsync("Authenticate?", account.Name + " → " + endpoint.Target,
                    "Authenticate", null, WorkspaceRoot.ActualTheme, _ => { });
                return result == ContentDialogResult.Primary && !dial.IsCancellationRequested;
            }
            var secrets = await IdentityAuthentication.CredentialsAsync(host, prompter, prompter, ConfirmIdentity);
            var route = new List<Tether.Jump>();
            foreach (var (hop, endpoint) in hops)
            {
                dial.ThrowIfCancellationRequested();
                var hopSecrets = await IdentityAuthentication.CredentialsAsync(endpoint, prompter, prompter, ConfirmIdentity);
                route.Add(new(hop.HostName, hop.Port, hop.User ?? Environment.UserName, hopSecrets));
            }
            if (dial.IsCancellationRequested || tab.Model.DialToken != dial || tab.Model.Generation != generation || (! _workspace.Contains(tab) && target is null)) return;
            tab.Model.NoteDialing();
            await tab.Model.ConnectAsync(Content.XamlRoot, new Destination(plan.Host, plan.Port, plan.User), secrets, route);
        }
        catch (Exception ex)
        {
            if (tab.Model.DialToken == dial && tab.Model.Generation == generation) tab.Model.Fail(ex.Message);
        }
        finally
        {
            _connecting = false;
            if (tab.Model.IsLive && tab.StartingDirectory is { } directory && !directory.Any(char.IsControl))
            {
                var quoted = "'" + directory.Replace("'", "'\"'\"'") + "'";
                if (Tether.KeyInput.FromVirtualKey(Windows.System.VirtualKey.None, false, false, false, "cd -- " + quoted + "\r") is { } input) tab.Model.Send(input);
                tab.StartingDirectory = null;
            }
            OnWorkspaceChanged();
            if (_workspace.Active == tab && tab.Model.IsLive && tab.OpenInspector is null) tab.Surface.FocusTerminal();
        }
    }

    private void CancelConnect_Click(object sender, RoutedEventArgs e) =>
        _workspace.Active?.Model.CancelDial();

    private async void Reconnect_Click(object sender, RoutedEventArgs e) => await RunCommandAsync("reconnect");

    private async Task ReconnectSelectedAsync()
    {
        if (_workspace.Active is not { } pane || !pane.Model.CanReconnect) return;
        if (pane.Model.RemoteHost is { } host) await OpenHostAsync(host, pane);
        else if (!await pane.Model.OpenLocalAsync(pane.Model.LocalProfile,
            directory: pane.Model.WorkingDirectory, wslDistribution: pane.Model.WslDistribution))
            throw new IOException(pane.Model.LastError ?? pane.Model.Status);
    }

    private void Settings_Click(object sender, RoutedEventArgs e)
    {
#if DEBUG
        if (_preview) return;
#endif
        // The same control as on macOS: it opens preferences. A window with
        // a sidebar is the Windows shape of `NavigationSplitView`.
        SettingsWindow.ShowFor(App.Plugins);
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        bool Down(Windows.System.VirtualKey key) => InputKeyboardSource.GetKeyStateForCurrentThread(key)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        if (e.OriginalSource is TextBox or PasswordBox or RichEditBox) return;
        e.Handled = HandleWorkspaceShortcut(new Shortcut(e.Key, Down(Windows.System.VirtualKey.Shift),
            Down(Windows.System.VirtualKey.Control), Down(Windows.System.VirtualKey.Menu)));
    }

    private void UpdateSplitButtons()
    {
        var state = CommandState;
        SplitRightButton.IsEnabled = WorkspaceCommands.IsEnabled("splitRight", state);
        SplitDownButton.IsEnabled = WorkspaceCommands.IsEnabled("splitDown", state);
        MaximizePaneButton.IsEnabled = WorkspaceCommands.IsEnabled("maximizePane", state);
        UpdateWorkspaceMenu();
        UpdateTabBarToggle();
    }

    private void UpdateTabBarToggle()
    {
        var shows = AppSettings.Current.ShowsTabBar;
        ToolTipService.SetToolTip(TabBarToggleButton, shows ? "Hide Tab Bar" : "Show Tab Bar");
        AutomationProperties.SetName(TabBarToggleButton, shows ? "Hide Tab Bar" : "Show Tab Bar");
        TabBarToggleButton.Opacity = shows ? 1 : 0.55;
    }

    private void TabBarToggle_Click(object sender, RoutedEventArgs e) => _ = RunCommandAsync("toggleTabBar");

    private async Task SplitSelectedAsync(bool vertical)
    {
        if (_splitting || _connecting || _workspace.Active is not { } source || (vertical ? source.Surface.ActualHeight < 205 : source.Surface.ActualWidth < 325)) return;
        _splitting = true;
        UpdateSplitButtons();
        try
        {
        var pane = await _workspace.SplitAsync(vertical);
        if (pane is null) return;
        if (source.Model.RemoteHost is { } host)
        {
            await OpenHostAsync(host, pane);
            if (!pane.Model.IsLive) { await _workspace.ClosePaneAsync(pane, remember: false); _workspace.Focus(source); return; }
        }
        pane.Surface.FocusTerminal();
        }
        finally { _splitting = false; UpdateSplitButtons(); }
    }
    private void FocusPane(int dx, int dy)
    {
        if (_workspace.Active is not { } source || _workspace.ActiveGroup is not { } group || group.Maximized) return;
        Windows.Foundation.Point Center(TerminalPane pane) => pane.Surface.TransformToVisual(TerminalHostPlaceholder)
            .TransformPoint(new Windows.Foundation.Point(pane.Surface.ActualWidth / 2, pane.Surface.ActualHeight / 2));
        var origin = Center(source);
        var target = group.Panes.Where(p => p != source && group.Layout.Leaves.Contains(p.Id)).Select(p => (Pane: p, Point: Center(p)))
            .Where(p => dx != 0 ? (p.Point.X - origin.X) * dx > 1 : (p.Point.Y - origin.Y) * dy > 1)
            .OrderBy(p => Math.Pow(p.Point.X - origin.X, 2) + Math.Pow(p.Point.Y - origin.Y, 2)).FirstOrDefault().Pane;
        if (target is not null) { _workspace.Focus(target); target.Surface.FocusTerminal(); }
    }

    private static async Task<string?> CloseNotesAsync(TerminalPane pane)
    {
        var notes = pane.Attachments.Select(a => a.CloseNote).Where(n => n is not null).Cast<string>().ToList();
        if (await ShellActivity.CloseNoteAsync(pane.Model) is { } shell) notes.Add(shell);
        return notes.Count == 0 ? null : string.Join("\n", notes);
    }

    private async Task CloseSelectedAsync()
    {
        if (_workspace.ActiveExtension is { } extension) { await CloseExtensionAsync(extension); return; }
        if (_workspace.Active is not { } pane) return;
        if (_workspace.ActiveGroup?.Panes.Count == 1) { await CloseTabAsync(_workspace.ActiveGroup); return; }
        var note = await CloseNotesAsync(pane);
        if (note is not null && await Alerts.ContentAsync("Close Pane?", note, "Close", null, WorkspaceRoot.ActualTheme, _ => { }) != ContentDialogResult.Primary) return;
        await _workspace.ClosePaneAsync(pane);
        _workspace.Active?.Surface.FocusTerminal();
    }

    private async Task CloseTabAsync(Tab tab)
    {
        var index = _workspace.VisibleTabs.ToList().IndexOf(tab);
        if (index < 0) return;
        if (!_closingTabs.Add(tab)) return;
        try
        {
            var notes = new List<string>();
            foreach (var pane in tab.Panes.ToArray())
            {
                var consequence = await CloseNotesAsync(pane);
                if (consequence is not null) notes.Add(pane.Title + ": " + consequence);
            }
            var note = notes.Count == 0 ? null : string.Join("\n", notes);
            if (note is not null)
            {
                _connecting = true;
                try
                {
                    if (await Alerts.ContentAsync("Close this tab?", note, "Close", null, WorkspaceRoot.ActualTheme,
                        _ => { }) != ContentDialogResult.Primary) return;
                }
                finally { _connecting = false; }
            }
        await _workspace.CloseAsync(_workspace.VisibleTabs.ToList().IndexOf(tab));
            if (_workspace.Tabs.Count == 0 && _workspace.Extensions.Count == 0 && AppSettings.Current.CloseLastTab == "quit")
            {
                _windowCloseApproved = true;
                Close();
            }
        }
        finally { _closingTabs.Remove(tab); }
    }
}
