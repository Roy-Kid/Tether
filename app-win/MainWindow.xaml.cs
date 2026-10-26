using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Tether;
using TetherApp.Files;
using TetherApp.Plugins;

namespace TetherApp;

public sealed partial class MainWindow : Window
{
    private TrayHost? _tray;
    private readonly Microsoft.UI.Dispatching.DispatcherQueue _workspaceQueue;
    private int _workspaceRefreshQueued;
    private volatile bool _windowClosed;
    private QuickTerminalController? _quickTerminal;
    private bool _refreshingTabs;
    private bool _revealPending;
    private bool _connecting;
    private int _connectGate;
    private bool _splitting;

    private void EnterConnect()
    {
        _connectGate++;
        _connecting = true;
    }

    private void LeaveConnect()
    {
        if (_connectGate > 0) _connectGate--;
        _connecting = _connectGate > 0;
    }
    private readonly HashSet<TerminalPane> _wiredPanes = [];
    private readonly Dictionary<Tab, SplitTerminalView> _splitViews = [];
    private Window? _hostPicker;
    private readonly Workspace _workspace = new();

    public MainWindow()
    {
        InitializeComponent();
        _workspaceQueue = DispatcherQueue;
        Closed += (_, _) =>
        {
            _windowClosed = true;
            _workspace.Changed -= RequestWorkspaceRefresh;
        };
        AppBranding.Apply(this);
        SystemBackdrop = new MicaBackdrop { Kind = Microsoft.UI.Composition.SystemBackdrops.MicaKind.BaseAlt };
        ExtendsContentIntoTitleBar = true;
        _dragArea = TitleBarDragArea;
        SetTitleBar(_dragArea);
        WorkspaceRoot.Loaded += (_, _) =>
        {
            var scale = WorkspaceRoot.XamlRoot.RasterizationScale;
            var area = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
            AppWindow.ResizeClient(new Windows.Graphics.SizeInt32(Math.Min((int)(1100 * scale), area.Width), Math.Min((int)(700 * scale), area.Height)));
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
        VerticalTabList.ContainerContentChanging += VerticalChipDrag;
        Closed += (_, _) => CompositionTarget.Rendering -= RevealSelectedTab;
        AppWindow.Closing += (sender, e) =>
        {
            if (_windowCloseApproved) return;
            if (_quickTerminal?.IsQuick == true)
            {
                e.Cancel = true;
                _quickTerminal.Hide();
                return;
            }
            if (_tray is null) return;
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
        _tray = new TrayHost(AppBranding.IconHandle,
            () => DispatcherQueue.TryEnqueue(ShowFromBackground),
            () => DispatcherQueue.TryEnqueue(() => _ = QuitAsync()));
        AppSettings.Load();
        WindowEffects.Observe(this, WorkspaceRoot, ApplyAppearance);
        _quickTerminal = new QuickTerminalController(WinRT.Interop.WindowNative.GetWindowHandle(this),
            action => DispatcherQueue.TryEnqueue(() => action()),
            () => _workspace.Active?.Surface.FocusTerminal(),
            () => _connecting || _checkingWindowClose || _commandPicker is not null || _hostPicker is not null);
        Closed += (_, _) => _quickTerminal.Dispose();
        BindTrayQuickTerminal();
        QuickTerminalController.Changed += BindTrayQuickTerminal;
        Closed += (_, _) => QuickTerminalController.Changed -= BindTrayQuickTerminal;
        AppSettings.Changed += ApplyAppearance;
        Closed += (_, _) => AppSettings.Changed -= ApplyAppearance;
        ApplyAppearance();
        _workspace.Changed += RequestWorkspaceRefresh;
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
        var labels = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        labels.Tick += (_, _) =>
        {
            if (_windowClosed || _connecting) return;
            RequestWorkspaceRefresh();
        };
        labels.Start();
        Closed += (_, _) => labels.Stop();
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
        _quickTerminal?.Apply(AppSettings.Current);
        WorkspaceRoot.RequestedTheme = Appearance.RequestedTheme;
        WindowEffects.Apply(this);
        ApplyTerminalPalette();
        UpdateTitleBar();
        ApplyWorkspaceVisibility();
    }

    private void ApplyTerminalPalette()
    {
        var palette = TerminalAppearance.Choose(WorkspaceRoot.ActualTheme == ElementTheme.Dark);
        WorkspaceRoot.Background = Appearance.WorkspaceBackground(palette, WorkspaceRoot.Background);
        _workspace.CurrentPalette = palette;
        Appearance.SetCanvas(TerminalAppearance.ForRendering(palette, WindowEffects.Opacity < 1));
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
        var header = Math.Max(32, Math.Ceiling(titleBar.Height / scale));
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

    private void RequestWorkspaceRefresh()
    {
        if (_windowClosed || Interlocked.Exchange(ref _workspaceRefreshQueued, 1) == 1) return;
        if (!_workspaceQueue.TryEnqueue(() =>
        {
            Interlocked.Exchange(ref _workspaceRefreshQueued, 0);
            if (!_windowClosed) OnWorkspaceChanged();
        })) Interlocked.Exchange(ref _workspaceRefreshQueued, 0);
    }

    private void OnWorkspaceChanged()
    {
        if (_windowClosed) return;
        _refreshingTabs = true;
        try
        {
            // Retain native tab containers and keyboard focus when selection changes.
            var panes = _workspace.VisiblePanes;
            foreach (var removed in TabStrip.TabItems.OfType<TabViewItem>()
                .Where(item => item.Tag switch
                {
                    TerminalPane pane => !panes.Contains(pane),
                    ExtensionTab extension => !_workspace.VisibleExtensions.Contains(extension),
                    _ => true,
                }).ToList())
                TabStrip.TabItems.Remove(removed);
            foreach (var pane in panes)
            {
                var title = _workspace.DisplayTitle(pane);
                var item = TabStrip.TabItems.OfType<TabViewItem>().FirstOrDefault(item => item.Tag == pane);
                if (item is null)
                {
                    item = CreateTab(title);
                    item.Tag = pane;
                    TabStrip.TabItems.Add(item);
                }
                ((WorkspaceTabHeader)item.Header).Update(title, title, false);
                AutomationProperties.SetName(item, title);
                ToolTipService.SetToolTip(item, title);
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
            var order = panes.Cast<object>().Concat(_workspace.VisibleExtensions.Cast<object>()).ToList();
            for (var index = 0; index < order.Count; index++)
            {
                var item = TabStrip.TabItems.OfType<TabViewItem>().First(candidate => Equals(candidate.Tag, order[index]));
                var position = TabStrip.TabItems.IndexOf(item);
                if (position != index)
                {
                    TabStrip.TabItems.RemoveAt(position);
                    TabStrip.TabItems.Insert(index, item);
                }
            }
            if (_workspace.ActiveExtension is { } activeExtension)
                TabStrip.SelectedItem = TabStrip.TabItems.OfType<TabViewItem>().FirstOrDefault(i => i.Tag == activeExtension);
            else if (_workspace.Active is { } active)
                TabStrip.SelectedItem = TabStrip.TabItems.OfType<TabViewItem>().FirstOrDefault(i => i.Tag == active);
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
        ShellLabel = string.IsNullOrWhiteSpace(_workspace.DisplayTitle(tab)) ? "Shell" : _workspace.DisplayTitle(tab),
        Shells = () => _workspace.AllPanes.Select(pane => new ShellChoice(pane.Id, _workspace.DisplayTitle(pane), pane == _workspace.Active)).ToArray(),
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
        tab.Surface.TerminalFocused = () =>
        {
            // Auth dialogs deactivate this window; when they close, the local
            // child HWND can grab focus and Focus() would flip CurrentHost back
            // to localhost mid-dial. Ignore until the connect finishes.
            if (_connecting || !_workspace.Contains(tab)) return;
            _workspace.Focus(tab);
        };
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
        InspectorHost.Width = Math.Clamp(InspectorHost.ActualWidth - e.HorizontalChange, minimum, Math.Max(minimum, Math.Min(480, WorkspaceRoot.ActualWidth * 0.7)));
    }

    private void VerticalTabsResize_DragDelta(object sender, DragDeltaEventArgs e) =>
        VerticalTabs.Width = Math.Clamp(VerticalTabs.ActualWidth + e.HorizontalChange, 180, 320);

    private TabViewItem CreateTab(string title)
    {
        var header = new WorkspaceTabHeader(title);
        var item = new TabViewItem { Header = header, Style = (Style)Application.Current.Resources["WorkspaceTabItemStyle"] };
        AutomationProperties.SetName(item, title);
        ToolTipService.SetToolTip(item, title);
        header.More.Click += (_, e) =>
        {
            if (item.Tag is TerminalPane pane) ShowTerminalMenu(header, pane);
        };
        var selectedBeforePress = false;
        item.PointerPressed += (_, e) =>
        {
            _suppressChipTap = false;
            selectedBeforePress = ReferenceEquals(TabStrip.SelectedItem, item);
            if (item.Tag is not TerminalPane pane) return;
            if (e.GetCurrentPoint(item).Properties.IsMiddleButtonPressed)
            {
                e.Handled = true;
                _ = CloseChipAsync(pane);
                return;
            }
            if (e.GetCurrentPoint(item).Properties.IsLeftButtonPressed && !FromButton(e.OriginalSource))
                BeginChipDrag(item, pane, e);
        };
        item.PointerMoved += (_, e) => MoveChipDrag(item, e);
        item.PointerReleased += (_, e) => EndChipDrag(item, e);
        item.PointerCaptureLost += (_, _) => CancelChipDrag();
        item.Tapped += (_, e) =>
        {
            if (_suppressChipTap) { _suppressChipTap = false; return; }
            if (!selectedBeforePress || item.Tag is not TerminalPane pane) return;
            for (var parent = e.OriginalSource as DependencyObject; parent is not null; parent = VisualTreeHelper.GetParent(parent))
                if (parent is Button) return;
            ShowTerminalMenu(header, pane);
        };
        item.RightTapped += (_, e) =>
        {
            if (item.Tag is TerminalPane pane) { e.Handled = true; ShowTerminalMenu(header, pane); }
        };
        return item;
    }

    private TabViewItem CreateExtensionTab(ExtensionTab extension)
    {
        var header = new WorkspaceTabHeader(extension.Title);
        header.UpdateExtension(extension);
        var item = new TabViewItem { Header = header, Tag = extension, Style = (Style)Application.Current.Resources["WorkspaceTabItemStyle"] };
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
            ShowMenu(header, [new("Close", () => _ = CloseExtensionAsync(open))]);
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
        if (selected.Tag is TerminalPane pane && (_workspace.Active != pane || _workspace.ActiveExtension is not null))
            _workspace.Focus(pane);
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
        else if (e.Tab.Tag is TerminalPane pane) await CloseChipAsync(pane);
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
        // A null remote host is the local workspace, whose name is localhost.
        // Keep its label just as we do for a selected SSH host.
        HostName.Visibility = Visibility.Visible;
        var bar = model?.Bar ?? RemoteBar.Idle();
        var live = bar.Phase == RemotePhase.Connected;
        StatusDot.Fill = (Brush)Application.Current.Resources[live ? "SuccessBrush" : "ChromeSubtleBrush"];
        StatusText.Text = live ? "" : bar.Status;
        var spoken = model?.LastError ?? model?.Status ?? "Not connected";
        StatusMark.Visibility = model is not null && !live && !bar.ShowsProgress && !bar.ShowsAuth && model.CanReconnect != true
            ? Visibility.Visible : Visibility.Collapsed;
        ToolTipService.SetToolTip(StatusMark, spoken);
        AutomationProperties.SetName(StatusMark, spoken);
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

        var resources = Application.Current.Resources;
        var rowHeight = (double)resources["PickerRowHeight"];
        var titleSize = (double)resources["TitleSize"];
        var symbolSize = (double)resources["SymbolSize"];
        var statusDot = (double)resources["StatusDotSize"];
        var spaceTight = (double)resources["SpaceTight"];
        var spaceInline = (double)resources["SpaceInline"];
        var spaceGroup = (double)resources["SpaceGroup"];
        var rowRadius = (CornerRadius)resources["RowRadius"];
        var textBrush = (Brush)resources["ChromeTextBrush"];
        var subtleBrush = (Brush)resources["ChromeSubtleBrush"];
        var raisedBrush = (Brush)resources["ChromeRaisedBrush"];
        var strokeBrush = (Brush)resources["ChromeStrokeBrush"];
        var successBrush = (Brush)resources["SuccessBrush"];
        var accentBrush = (Brush)resources["AccentBrush"];
        var clear = new SolidColorBrush(Microsoft.UI.Colors.Transparent);

        var query = new TextBox
        {
            PlaceholderText = "Find a host…",
            FontSize = titleSize,
            BorderThickness = new Thickness(0),
            Background = raisedBrush,
            Padding = new Thickness(spaceGroup, spaceInline, spaceGroup, spaceInline),
            CornerRadius = rowRadius,
        };
        var problem = new TextBlock
        {
            Text = "No matching hosts.",
            FontSize = titleSize,
            TextWrapping = TextWrapping.Wrap,
            Foreground = subtleBrush,
            Visibility = Visibility.Collapsed,
            Margin = new Thickness(0, spaceTight, 0, 0),
        };
        var rows = new StackPanel { Spacing = spaceTight };
        var scroll = new ScrollViewer
        {
            MaxHeight = (double)resources["PickerListHeight"],
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = rows,
        };
        var selectable = new List<HostRow>();
        var highlights = new List<Border>();
        var selected = -1;

        void PaintSelection()
        {
            for (var index = 0; index < highlights.Count; index++)
                highlights[index].Opacity = index == selected ? 0.12 : 0;
        }

        void Select(int index)
        {
            if (selectable.Count == 0) { selected = -1; PaintSelection(); return; }
            selected = Math.Clamp(index, 0, selectable.Count - 1);
            PaintSelection();
            if (selected >= 0 && selected < highlights.Count)
                highlights[selected].StartBringIntoView();
        }

        Button HostChromeRow(HostRow row, int index)
        {
            var live = new Ellipse
            {
                Width = statusDot,
                Height = statusDot,
                Fill = row.Connected ? successBrush : clear,
                VerticalAlignment = VerticalAlignment.Center,
            };
            var label = new TextBlock
            {
                Text = row.Host?.Label ?? "localhost",
                FontSize = titleSize,
                Foreground = textBrush,
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            var check = new FontIcon
            {
                Glyph = "\uE73E",
                FontSize = 10,
                Foreground = row.Current ? textBrush : clear,
                VerticalAlignment = VerticalAlignment.Center,
            };
            var content = new Grid { ColumnSpacing = spaceGroup, Padding = new Thickness(spaceInline, 0, spaceInline, 0) };
            content.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            content.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
            content.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            content.Children.Add(live);
            Grid.SetColumn(label, 1); content.Children.Add(label);
            Grid.SetColumn(check, 2); content.Children.Add(check);
            var wash = new Border
            {
                Background = accentBrush,
                CornerRadius = rowRadius,
                Opacity = 0,
                MinHeight = rowHeight,
            };
            var root = new Grid { MinHeight = rowHeight };
            root.Children.Add(wash);
            root.Children.Add(content);
            var button = new Button
            {
                Content = root,
                Style = (Style)resources["ChromeButtonStyle"],
                Padding = new Thickness(0),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
            };
            ToolTipService.SetToolTip(button, row.Connected ? (row.Host?.Label ?? "localhost") + " · connected" : row.Host?.Label ?? "localhost");
            AutomationProperties.SetName(button, row.Host?.Label ?? "localhost");
            button.Click += async (_, _) => await ChooseHostAsync(row.Host);
            button.PointerEntered += (_, _) => Select(index);
            highlights.Add(wash);
            return button;
        }

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
                rows.Children.Clear();
                selectable.Clear();
                highlights.Clear();
                selected = -1;
                scroll.Visibility = Visibility.Collapsed;
                return;
            }
            problem.Text = "No matching hosts.";
            rows.Children.Clear();
            selectable.Clear();
            highlights.Clear();
            var matches = SshConfig.Filter(all, query.Text).ToList();
            var connected = matches.Where(IsConnectedHost).ToList();
            if (_workspace.CurrentHost is { } current && matches.Any(h => h.Alias == current.Alias))
                connected = [current, .. connected.Where(h => h.Alias != current.Alias)];
            var connectedAliases = connected.Select(h => h.Alias).ToHashSet();
            var idle = matches.Where(h => !connectedAliases.Contains(h.Alias)).ToList();
            var localMatch = "localhost".Contains(query.Text.Trim(), StringComparison.OrdinalIgnoreCase);
            var entries = new List<HostRow>();
            if (localMatch && _workspace.CurrentHost is null)
                entries.Add(new(null, connected: _workspace.AllPanes.Any(p => p.Model.IsLive && p.Model.RemoteHost is null), current: true));
            foreach (var host in connected)
                entries.Add(new(host, connected: true, current: SameHost(host, _workspace.CurrentHost)));
            var needDivider = connected.Count > 0 && (idle.Count > 0 || (localMatch && _workspace.CurrentHost is not null));
            if (localMatch && _workspace.CurrentHost is not null)
                entries.Add(new(null));
            foreach (var host in idle) entries.Add(new(host, current: SameHost(host, _workspace.CurrentHost)));

            var liveCount = (localMatch && _workspace.CurrentHost is null ? 1 : 0) + connected.Count;
            for (var index = 0; index < entries.Count; index++)
            {
                if (needDivider && index == liveCount && liveCount > 0)
                    rows.Children.Add(new Border
                    {
                        Height = 1,
                        Margin = new Thickness(spaceInline, spaceTight, spaceInline, spaceTight),
                        Background = strokeBrush,
                    });
                var row = entries[index];
                var visual = HostChromeRow(row, selectable.Count);
                selectable.Add(row);
                rows.Children.Add(visual);
            }
            var any = selectable.Count > 0;
            Select(any ? 0 : -1);
            problem.Visibility = any ? Visibility.Collapsed : Visibility.Visible;
            scroll.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
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
                if (index < selectable.Count) { e.Handled = true; await ChooseHostAsync(selectable[index].Host); }
                return;
            }
            if (e.Key is Windows.System.VirtualKey.Down or Windows.System.VirtualKey.Up)
            {
                if (selectable.Count > 0)
                    Select(selected + (e.Key == Windows.System.VirtualKey.Down ? 1 : -1));
                e.Handled = true;
            }
            else if (e.Key == Windows.System.VirtualKey.Enter && selected >= 0 && selected < selectable.Count)
            {
                e.Handled = true;
                await ChooseHostAsync(selectable[selected].Host);
            }
        };

        var panel = new StackPanel
        {
            Spacing = spaceGroup,
            Padding = new Thickness(12),
            RequestedTheme = WorkspaceRoot.ActualTheme,
            Background = raisedBrush,
        };
        var searchRow = new Grid { ColumnSpacing = spaceGroup };
        searchRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        searchRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        searchRow.Children.Add(query);
        var manage = new Button
        {
            Content = "\uE70F",
            Style = (Style)resources["ChromeIconButtonStyle"],
            Foreground = subtleBrush,
        };
        ToolTipService.SetToolTip(manage, "Manage Hosts");
        AutomationProperties.SetName(manage, "Manage Hosts");
        manage.Click += (_, _) => { _hostPicker?.Close(); _ = RunCommandAsync("manageHosts"); };
        Grid.SetColumn(manage, 1); searchRow.Children.Add(manage);
        panel.Children.Add(searchRow);
        panel.Children.Add(problem);
        panel.Children.Add(scroll);

        var window = new Window { Title = "Hosts", Content = panel };
        AppBranding.Apply(window);
        var presenter = Microsoft.UI.Windowing.OverlappedPresenter.Create();
        presenter.SetBorderAndTitleBar(true, false);
        presenter.IsResizable = false;
        presenter.IsMinimizable = false;
        presenter.IsMaximizable = false;
        presenter.IsAlwaysOnTop = false;
        window.AppWindow.SetPresenter(presenter);
        var preferredWidth = (int)(double)resources["PickerWidth"];
        const int preferredHeight = 320;
        void FitToOwner()
        {
            if (_hostPicker != window) return;
            if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter
                { State: Microsoft.UI.Windowing.OverlappedPresenterState.Minimized })
            {
                window.Close();
                return;
            }
            var owner = AppWindow.Size;
            var width = Math.Min(preferredWidth, Math.Max(200, owner.Width - 24));
            var height = Math.Min(preferredHeight, Math.Max(140, owner.Height - 48));
            scroll.MaxHeight = Math.Max(80, height - 88);
            WindowPlacement.Above(this, HostButton, window, width, height);
        }
        void OnOwnerChanged(Microsoft.UI.Windowing.AppWindow _, Microsoft.UI.Windowing.AppWindowChangedEventArgs e)
        {
            if (e.DidPositionChange || e.DidSizeChange || e.DidPresenterChange) FitToOwner();
        }
        AppWindow.Changed += OnOwnerChanged;
        window.Closed += (_, _) =>
        {
            AppWindow.Changed -= OnOwnerChanged;
            if (_hostPicker == window) _hostPicker = null;
        };
        WindowPlacement.Own(window, topmost: false);
        _hostPicker = window;
        FitToOwner();
        window.Activate();
        query.Focus(FocusState.Programmatic);
        Reload();
    }

    private static bool SameHost(HostEntry? left, HostEntry? right) =>
        left is null && right is null ||
        left is not null && right is not null &&
        IdentityStore.EndpointDigest(left) == IdentityStore.EndpointDigest(right);

    private static void RememberRecentHost(HostEntry? host)
    {
        var alias = host?.Alias ?? "local";
        var recent = AppSettings.Current.RecentHosts.Where(a => a != alias).Prepend(alias).Take(8).ToArray();
        (AppSettings.Current with { RecentHosts = recent }).Save();
    }

    private bool IsConnectedHost(HostEntry host) =>
        _workspace.AllPanes.Any(pane => pane.Model.IsLive && pane.Model.RemoteHost is { } current &&
            IdentityStore.EndpointDigest(current) == IdentityStore.EndpointDigest(host));

    private sealed class HostRow(HostEntry? host, bool connected = false, bool current = false)
    {
        public HostEntry? Host { get; } = host;
        public bool Connected { get; } = connected;
        public bool Current { get; } = current;
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
        EnterConnect();
        try
        {
            RememberRecentHost(host);
            _workspace.SelectHost(host);
            if (_workspace.VisibleTabs.Count == 0)
                await _workspace.AddAsync(ConnectPaneAsync);
            else if (host is not null && _workspace.Active is { Model.IsLive: false } pane)
            {
                // A prior dial left the host selected with a dead pane — dial again
                // instead of stranding the person on an empty Arrhenius workspace.
                await OpenHostAsync(host, pane);
                await ReportConnectionFailureAsync(pane);
            }
            // Re-assert the host after dial: dialog teardown can otherwise leave
            // the window showing localhost while the remote tab sits invisible.
            _workspace.SelectHost(host);
            if (_workspace.Active is { Model.IsLive: true } live)
                live.Surface.FocusTerminal();
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            await Alerts.ContentAsync(host?.Label ?? "localhost", ex.Message, "Close", null,
                WorkspaceRoot.ActualTheme, _ => { });
        }
        finally
        {
            LeaveConnect();
            _hostRequests.Remove(key);
            completion.TrySetResult();
            OnWorkspaceChanged();
        }
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
        EnterConnect();
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
            LeaveConnect();
            if (tab.Model.IsLive && tab.StartingDirectory is { } directory && !directory.Any(char.IsControl))
            {
                var quoted = "'" + directory.Replace("'", "'\"'\"'") + "'";
                if (Tether.KeyInput.FromVirtualKey(Windows.System.VirtualKey.None, false, false, false, "cd -- " + quoted + "\r") is { } input) tab.Model.Send(input);
                tab.StartingDirectory = null;
            }
            // Tab may not be in the workspace yet (AddAsync parents after connect).
            // A direct refresh here would paint the empty Arrhenius host; the
            // workspace Changed event after AddAsync is the one that sticks.
            if (_workspace.Contains(tab))
            {
                OnWorkspaceChanged();
                if (_workspace.Active == tab && tab.Model.IsLive && tab.OpenInspector is null)
                    tab.Surface.FocusTerminal();
            }
        }
    }

    private void CancelConnect_Click(object sender, RoutedEventArgs e) =>
        _workspace.Active?.Model.CancelDial();

    private async void Reconnect_Click(object sender, RoutedEventArgs e) => await RunCommandAsync("reconnect");

    private async Task ReconnectSelectedAsync()
    {
        if (_workspace.Active is not { } pane || !pane.Model.CanReconnect) return;
        if (pane.Model.RemoteHost is { } host)
        {
            await OpenHostAsync(host, pane);
            await ReportConnectionFailureAsync(pane);
        }
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
        // Split is only on the tab context menu (macOS parity) — not status-bar icons.
        var state = CommandState;
        var show = _workspace.Active is not null && !_zen && state.VisibleTerminals > 1;
        MaximizePaneButton.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
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

    private async Task SplitSelectedAsync(SplitEdge edge)
    {
        var vertical = edge is SplitEdge.Up or SplitEdge.Down;
        if (_splitting || _connecting || _workspace.Active is not { } source || (vertical ? source.Surface.ActualHeight < 205 : source.Surface.ActualWidth < 325)) return;
        _splitting = true;
        UpdateSplitButtons();
        try
        {
        var pane = await _workspace.SplitAsync(edge);
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
        if (note is not null && await Alerts.ContentAsync("Close Terminal?", note, "Close", null, WorkspaceRoot.ActualTheme, _ => { }) != ContentDialogResult.Primary) return;
        await _workspace.ClosePaneAsync(pane);
        _workspace.Active?.Surface.FocusTerminal();
    }

    private async Task CloseChipAsync(TerminalPane pane)
    {
        var group = _workspace.Tabs.FirstOrDefault(tab => tab.Panes.Contains(pane));
        if (group is null) return;
        if (group.Panes.Count == 1)
        {
            await CloseTabAsync(group);
            return;
        }
        _workspace.Focus(pane);
        await CloseSelectedAsync();
    }

    private static bool FromButton(object source)
    {
        for (var parent = source as DependencyObject; parent is not null; parent = VisualTreeHelper.GetParent(parent))
            if (parent is Button) return true;
        return false;
    }

    private TerminalPane? _dragging;
    private bool _dragArmed, _suppressChipTap;
    private FrameworkElement? _dropMark;
    private Windows.Foundation.Point _dragOrigin;

    private readonly HashSet<ListViewItem> _chipDragWired = [];

    private void VerticalChipDrag(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.ItemContainer is not ListViewItem row || !_chipDragWired.Add(row)) return;
        row.PointerPressed += (_, e) =>
        {
            _suppressChipTap = false;
            if (row.DataContext is not VerticalPaneRow item || !e.GetCurrentPoint(row).Properties.IsLeftButtonPressed) return;
            BeginChipDrag(row, item.Pane, e);
        };
        row.PointerMoved += (_, e) => MoveChipDrag(row, e);
        row.PointerReleased += (_, e) => EndChipDrag(row, e);
        row.PointerCaptureLost += (_, _) => CancelChipDrag();
    }

    private void BeginChipDrag(UIElement element, TerminalPane pane, PointerRoutedEventArgs e)
    {
        _dragging = pane;
        _dragArmed = false;
        _dragOrigin = e.GetCurrentPoint(WorkspaceRoot).Position;
        element.CapturePointer(e.Pointer);
    }

    private void MoveChipDrag(UIElement element, PointerRoutedEventArgs e)
    {
        if (_dragging is null || element.PointerCaptures?.Contains(e.Pointer) != true) return;
        var point = e.GetCurrentPoint(WorkspaceRoot).Position;
        var dx = point.X - _dragOrigin.X;
        var dy = point.Y - _dragOrigin.Y;
        if (!_dragArmed && dx * dx + dy * dy <= 36) return;
        _dragArmed = true;
        e.Handled = true;
        if (ChipAt(point, _dragging) is { } hit) ShowDropMark(hit.Element, hit.Edge);
        else ClearDropMark();
    }

    private void EndChipDrag(UIElement element, PointerRoutedEventArgs e)
    {
        var dragged = _dragging;
        var armed = _dragArmed;
        _dragging = null;
        _dragArmed = false;
        if (armed) _suppressChipTap = true;
        // PointerCaptures is null, not empty, when nothing was captured (a right click).
        if (element.PointerCaptures?.Contains(e.Pointer) == true) element.ReleasePointerCapture(e.Pointer);
        var hit = armed && dragged is not null ? ChipAt(e.GetCurrentPoint(WorkspaceRoot).Position, dragged) : null;
        ClearDropMark();
        if (hit is { } target && dragged is not null && _workspace.Place(dragged, target.Pane, target.Edge))
            _workspace.Active?.Surface.FocusTerminal();
    }

    private void CancelChipDrag()
    {
        _dragging = null;
        _dragArmed = false;
        ClearDropMark();
    }

    private (TerminalPane Pane, FrameworkElement Element, SplitEdge Edge)? ChipAt(Windows.Foundation.Point point, TerminalPane dragged)
    {
        foreach (var hit in VisualTreeHelper.FindElementsInHostCoordinates(point, WorkspaceRoot))
        {
            for (var node = hit as DependencyObject; node is not null; node = VisualTreeHelper.GetParent(node))
            {
                FrameworkElement? element = node switch
                {
                    TabViewItem item when item.Tag is TerminalPane pane && pane != dragged => item,
                    ListViewItem row when row.DataContext is VerticalPaneRow vertical && vertical.Pane != dragged => row,
                    _ => null,
                };
                if (element is null) continue;
                var targetPane = element is TabViewItem tab ? (TerminalPane)tab.Tag : ((VerticalPaneRow)element.DataContext).Pane;
                var origin = element.TransformToVisual(WorkspaceRoot).TransformPoint(new Windows.Foundation.Point(0, 0));
                var edge = SplitEdges.DropOnChip(point.X - origin.X, point.Y - origin.Y, element.ActualWidth, element.ActualHeight);
                return (targetPane, element, edge);
            }
        }
        return null;
    }

    private void ShowDropMark(FrameworkElement element, SplitEdge edge)
    {
        if (!ReferenceEquals(_dropMark, element)) ClearDropMark();
        _dropMark = element;
        if (element is TabViewItem item && item.Header is WorkspaceTabHeader header) header.ShowDrop(edge);
        else
        {
            element.SetValue(Control.BorderBrushProperty, Application.Current.Resources["AccentBrush"]);
            element.SetValue(Control.BorderThicknessProperty, edge switch
            {
                SplitEdge.Left => new Thickness(3, 0, 0, 0),
                SplitEdge.Right => new Thickness(0, 0, 3, 0),
                SplitEdge.Up => new Thickness(0, 3, 0, 0),
                _ => new Thickness(0, 0, 0, 3),
            });
        }
    }

    private void ClearDropMark()
    {
        if (_dropMark is TabViewItem item && item.Header is WorkspaceTabHeader header) header.ShowDrop(null);
        else if (_dropMark is not null)
        {
            _dropMark.ClearValue(Control.BorderBrushProperty);
            _dropMark.ClearValue(Control.BorderThicknessProperty);
        }
        _dropMark = null;
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
