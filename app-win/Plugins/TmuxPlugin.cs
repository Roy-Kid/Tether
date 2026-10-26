using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Tether;
using Windows.System;

namespace TetherApp.Plugins;

// Same chooser as macOS: one level at a time, shell rows, then tmux sessions.
// On Windows this is a trailing inspector (macOS SF Symbol rectangle.3.offgrid).
public sealed class TmuxPlugin : ITabPlugin
{
    // Segoe Fluent Icons GridViewSmall — the closest multi-pane glyph to
    // macOS rectangle.3.offgrid. OpenInNewWindow (\uE8A7) was wrong.
    private const string Glyph = "\uF232";
    public PluginMetadata Metadata { get; } = new("dev.tether.tmux", "tmux", Glyph, "Persistent sessions, in the terminal itself.");
    public TabAccessory Accessory { get; } = new(Glyph, "tmux sessions", AccessoryPlacement.Inspector);
    public IReadOnlyList<PluginCommandDescriptor> CommandDescriptors =>
    [
        new("detach", "Detach Session"),
        new("newWindow", "New Window"),
        new("splitHorizontal", "Split Left and Right"),
        new("splitVertical", "Split Top and Bottom"),
        new("zoom", "Zoom Pane"),
    ];
    public void Activate() { }
    public void Deactivate() { }
    public ITabAttachment Attach(TabContext tab) => new TmuxAttachment(tab);
}

sealed class TmuxAttachment : ITabAttachment
{
    private readonly TabContext _tab;
    private readonly StackPanel _panel = new() { Padding = new Thickness(8), Spacing = 0 };
    private readonly TextBlock _host;
    private readonly StackPanel _rows = new() { Spacing = 2 };
    private readonly TextBlock _problem;
    private readonly ProgressRing _busyMark = new()
    {
        Width = 14, Height = 14, IsActive = false, Visibility = Visibility.Collapsed,
        HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 0, 0, 4),
    };
    private readonly CancellationTokenSource _lifetime = new();
    private readonly List<Row> _keyboard = [];
    private IReadOnlyList<TmuxSessionInfo> _sessions = [];
    private string? _tty, _session, _opened, _highlight, _pendingRestore;
    private Action _dismiss;
    private bool _busy, _missing;
    private string? _error;

    public TmuxAttachment(TabContext tab)
    {
        _tab = tab;
        var resources = Application.Current.Resources;
        _host = new TextBlock
        {
            Text = "",
            FontSize = (double)resources["HeaderSize"],
            Foreground = (Brush)resources["ChromeSubtleBrush"],
            Margin = new Thickness(4, 0, 4, 6),
        };
        _problem = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            FontSize = (double)resources["DetailSize"],
            Foreground = (Brush)resources["ChromeSubtleBrush"],
            Margin = new Thickness(4, 6, 4, 0),
        };
        _panel.Children.Add(_host);
        _panel.Children.Add(_busyMark);
        _panel.Children.Add(_rows);
        _panel.Children.Add(_problem);
        _dismiss = tab.Dismiss;
        _panel.KeyDown += OnKeyDown;
        _tab.Model.SessionChanged += SessionChanged;
    }

    public void UseDismiss(Action dismiss) => _dismiss = dismiss;

    public UIElement View => _panel;
    public string? CloseNote => _session is null ? null : "tmux stays on the host.";
    public string TabTitle
    {
        get
        {
            if (_session is null) return "";
            return _sessions.FirstOrDefault(session => session.Id == _session)?.Name ?? "";
        }
    }
    public string? RestorationState => _session;
    public IReadOnlyList<PluginCommand> Commands => _session is null ? [] :
    [
        new("detach", "Detach Session", () => RunAsync(async () => { await DetachAsync(); _dismiss(); })),
        new("newWindow", "New window", () => PerformAsync("new-window")),
        new("splitHorizontal", "Split left and right", () => PerformAsync("split-window -h")),
        new("splitVertical", "Split top and bottom", () => PerformAsync("split-window -v")),
        new("zoom", "Zoom pane", () => PerformAsync("resize-pane -Z")),
    ];
    public Task RestoreAsync(string state) { _pendingRestore = state; return Task.CompletedTask; }
    public Task ShownAsync() { _panel.Focus(FocusState.Programmatic); return RunAsync(RefreshAsync); }
    public bool Receive(IReadOnlyList<string> paths) => false;
    public LinkActions? ActionsFor(TerminalLink link) => null;

    private void SessionChanged()
    {
        _panel.DispatcherQueue.TryEnqueue(async () =>
        {
            _tty = null; _session = null;
            if (!_tab.Model.IsLive || _lifetime.IsCancellationRequested) return;
            await RunAsync(RefreshAsync);
        });
    }

    private async Task RunAsync(Func<Task> action)
    {
        if (_busy || _lifetime.IsCancellationRequested) return;
        _busy = true; _error = null; _problem.Text = "";
        _busyMark.IsActive = true; _busyMark.Visibility = Visibility.Visible;
        try { await action(); }
        catch (OperationCanceledException) { }
        catch (Exception ex) { _error = ex.Message; _problem.Text = ex.Message; }
        finally { _busy = false; _busyMark.IsActive = false; _busyMark.Visibility = Visibility.Collapsed; Render(); }
    }

    private async Task RefreshAsync()
    {
        _missing = false;
        _error = null;
        if (!_tab.Model.IsLive) { _sessions = []; return; }
        // Local Windows shells have no RemoteConnection — tmux only runs in WSL
        // or over SSH. Do not surface the internal "No live connection" string.
        if (!_tab.Model.IsRemote && !_tab.Model.IsWsl)
        {
            _sessions = [];
            _missing = true;
            return;
        }
        try
        {
            _sessions = await _tab.Model.TmuxSessionsAsync(_lifetime.Token);
            _tty = await ShellTTY.FindAsync(_tab.Model, _lifetime.Token);
            _session = _tty is null ? null : await _tab.Model.TmuxSessionForClientAsync(_tty);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _sessions = [];
            var text = ex.Message;
            // Match macOS TmuxTab.refresh: only treat a missing binary as "isn't installed".
            // "No live session/connection" is not that — never map it to the install hint.
            _missing = text.Contains("not installed", StringComparison.OrdinalIgnoreCase)
                || text.Contains("Install tmux", StringComparison.OrdinalIgnoreCase)
                || text.Contains("no such file", StringComparison.OrdinalIgnoreCase)
                || text.Contains("not found", StringComparison.OrdinalIgnoreCase)
                || text.Contains("No live connection", StringComparison.OrdinalIgnoreCase);
            if (!_missing) throw;
        }
        if (_pendingRestore is { } id && _sessions.FirstOrDefault(s => s.Id == id) is { } saved)
        { _pendingRestore = null; await OpenAsync(saved, null); }
    }

    private sealed record Row(string Id, string Title, bool Mark, bool Chevron, Action? Run, string? EndTitle, Action? End, Action<MenuFlyout>? Menu);

    private void Render()
    {
        _host.Text = _tab.HostLabel;
        _rows.Children.Clear();
        _keyboard.Clear();
        if (_opened is { } opened && _sessions.FirstOrDefault(session => session.Id == opened) is { } session)
            RenderWindows(session);
        else
            RenderRoot();
        if (_keyboard.Count > 0 && _keyboard.All(row => row.Id != _highlight)) _highlight = _keyboard[0].Id;
        _problem.Text = _missing ? "tmux isn’t installed" : _error ?? "";
    }

    private void RenderRoot()
    {
        var shells = _tab.Shells();
        if (shells.Count > 1)
            foreach (var shell in shells)
                Add(new($"shell:{shell.Id}", shell.Title, shell.Current && _session is null, false, () => { _tab.OpenShell(shell.Id); _dismiss(); }, null, null, null));
        if (shells.Count < 2 || _session is not null)
            Add(new("shell", _tab.ShellLabel, _session is null, false, () => _ = RunAsync(ShowShellAsync), null, null, null));
        Add(new("new-shell", "New shell…", false, false, () => { _tab.NewShell(); _dismiss(); }, null, null, null));
        AddHeader("tmux sessions");
        foreach (var session in _sessions)
        {
            var windows = session.Windows;
            var owned = _session == session.Id;
            var deeper = windows.Count > 1;
            var line = $"{session.Name}: {windows.Count} windows";
            if (owned || session.Attached) line += " (attached)";
            Add(new($"session:{session.Id}", line, owned, deeper, () =>
            {
                if (deeper) { _opened = session.Id; Render(); }
                // macOS inspector stays open after choose — pick another without reopening.
                else _ = RunAsync(async () => await OpenAsync(session, windows.FirstOrDefault()));
            }, "End session", () => _ = ConfirmEndSession(session), menu => SessionMenu(menu, session, owned)));
        }
        Add(new("new-session", "New session…", false, false, () => _ = RunAsync(CreateAsync), null, null, null));
    }

    private void RenderWindows(TmuxSessionInfo session)
    {
        Add(new("back", session.Name, false, false, () => { _opened = null; Render(); }, null, null, null));
        foreach (var window in session.Windows)
        {
            var line = $"{window.Index}: {window.Name}{(window.Active ? "*" : "")} ({window.Panes} panes)";
            var end = session.Windows.Count > 1;
            Add(new($"window:{window.Id}", line, window.Active && _session == session.Id, false,
                () => _ = RunAsync(async () => await OpenAsync(session, window)),
                end ? "End window" : null, end ? () => _ = ConfirmEndWindow(window) : null,
                menu => WindowMenu(menu, window, end)));
        }
        if (_session == session.Id)
            Add(new("new-window", "New window", false, false, () => _ = PerformAsync("new-window"), null, null, null));
    }

    private void AddHeader(string text)
    {
        var resources = Application.Current.Resources;
        _rows.Children.Add(new Border
        {
            Height = 1,
            Background = (Brush)resources["ChromeStrokeBrush"],
            Margin = new Thickness(4, 8, 4, 4),
        });
        _rows.Children.Add(new TextBlock
        {
            Text = text,
            FontSize = (double)resources["HeaderSize"],
            Foreground = (Brush)resources["ChromeSubtleBrush"],
            Margin = new Thickness(4, 2, 4, 4),
        });
    }

    private void Add(Row row)
    {
        if (row.Run is not null) _keyboard.Add(row);
        var resources = Application.Current.Resources;
        var rowHeight = (double)resources["CompactControlHeight"];
        var spaceInline = (double)resources["SpaceInline"];
        var spaceGroup = (double)resources["SpaceGroup"];
        var textBrush = (Brush)resources["ChromeTextBrush"];
        var subtleBrush = (Brush)resources["ChromeSubtleBrush"];
        var accentBrush = (Brush)resources["AccentBrush"];
        var clear = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        var selected = row.Id == _highlight;

        var isBack = row.Id == "back";
        var leading = isBack
            ? (UIElement)new FontIcon { Glyph = "\uE76B", FontSize = 10, Foreground = subtleBrush, VerticalAlignment = VerticalAlignment.Center }
            : new FontIcon
            {
                Glyph = "\uE73E",
                FontSize = 10,
                Foreground = row.Mark ? textBrush : clear,
                VerticalAlignment = VerticalAlignment.Center,
                Width = 12,
            };
        var title = new TextBlock
        {
            Text = row.Title,
            FontSize = (double)resources[isBack ? "HeaderSize" : "TitleSize"],
            Foreground = isBack ? subtleBrush : textBrush,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };

        var end = new Button
        {
            Content = "\uE711",
            Style = (Style)resources["ChromeIconButtonStyle"],
            Visibility = Visibility.Collapsed,
            IsEnabled = row.End is not null,
        };
        if (row.EndTitle is not null) ToolTipService.SetToolTip(end, row.EndTitle);
        if (row.End is { } endAction) end.Click += (_, _) => endAction();

        FrameworkElement trailing = row.Chevron
            ? new FontIcon { Glyph = "\uE76C", FontSize = 9, Foreground = subtleBrush, VerticalAlignment = VerticalAlignment.Center }
            : end;

        var content = new Grid { ColumnSpacing = spaceGroup, Padding = new Thickness(spaceInline, 0, spaceInline, 0) };
        content.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        content.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        content.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        if (leading is FrameworkElement lead) content.Children.Add(lead);
        Grid.SetColumn(title, 1); content.Children.Add(title);
        Grid.SetColumn(trailing, 2); content.Children.Add(trailing);

        var wash = new Border
        {
            Background = accentBrush,
            CornerRadius = (CornerRadius)resources["RowRadius"],
            Opacity = selected ? 0.12 : 0,
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
            IsEnabled = !_busy || row.Id == "back",
        };
        button.Click += (_, _) => { _highlight = row.Id; row.Run?.Invoke(); };
        if (row.End is not null)
        {
            button.PointerEntered += (_, _) => end.Visibility = Visibility.Visible;
            button.PointerExited += (_, _) => end.Visibility = Visibility.Collapsed;
        }
        if (row.Menu is not null)
        {
            var menu = new MenuFlyout();
            row.Menu(menu);
            button.ContextFlyout = menu;
        }
        AutomationProperties.SetName(button, row.Title);
        _rows.Children.Add(button);
    }

    private void SessionMenu(MenuFlyout menu, TmuxSessionInfo session, bool owned)
    {
        menu.Items.Add(Item("Rename…", () => _ = RunAsync(() => RenameSessionAsync(session))));
        if (owned) menu.Items.Add(Item("Detach session", () => _ = RunAsync(async () => { await DetachAsync(); _dismiss(); })));
        menu.Items.Add(Item("End session…", () => _ = RunAsync(() => ConfirmEndSession(session))));
    }

    private void WindowMenu(MenuFlyout menu, TmuxWindow window, bool canEnd)
    {
        menu.Items.Add(Item("Rename…", () => _ = RunAsync(() => RenameWindowAsync(window))));
        if (canEnd) menu.Items.Add(Item("End window…", () => _ = RunAsync(() => ConfirmEndWindow(window))));
    }

    private static MenuFlyoutItem Item(string title, Action run)
    {
        var item = new MenuFlyoutItem { Text = title };
        item.Click += (_, _) => run();
        return item;
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Escape)
        {
            e.Handled = true;
            if (_opened is not null) { _opened = null; Render(); }
            else _dismiss();
            return;
        }
        if (_keyboard.Count == 0) return;
        var index = Math.Max(0, _keyboard.FindIndex(row => row.Id == _highlight));
        if (e.Key == VirtualKey.Down) { e.Handled = true; _highlight = _keyboard[Math.Min(_keyboard.Count - 1, index + 1)].Id; Render(); }
        else if (e.Key == VirtualKey.Up) { e.Handled = true; _highlight = _keyboard[Math.Max(0, index - 1)].Id; Render(); }
        else if (e.Key == VirtualKey.Enter) { e.Handled = true; _keyboard[index].Run?.Invoke(); }
        else if (e.Key == VirtualKey.Left && _opened is not null) { e.Handled = true; _opened = null; Render(); }
        else if (e.Key == VirtualKey.Right && _opened is null && _keyboard[index].Chevron) { e.Handled = true; _keyboard[index].Run?.Invoke(); }
    }

    private async Task OpenAsync(TmuxSessionInfo selected, TmuxWindow? window)
    {
        // Already on this session with no window change — leave the inspector open.
        if (_session == selected.Id && window is null) return;
        if (_tty is null) throw new IOException("Unable to identify this terminal.");
        var target = SessionId(selected.Id);
        var current = await _tab.Model.TmuxSessionForClientAsync(_tty);
        if (current is not null)
            await _tab.Model.ExecuteAsync("tmux switch-client -c " + Quote(_tty) + " -t " + target, _lifetime.Token);
        else
        {
            _tab.Model.Send(new TerminalInput.Key(new KeyPress.Char("u"), new KeyModifiers(Control: true)));
            _tab.Model.Send(new TerminalInput.Paste("tmux attach-session -t " + target));
            _tab.Model.Send(new TerminalInput.Key(new KeyPress.Enter(), new KeyModifiers()));
        }
        if (window is not null) await _tab.Model.ExecuteAsync($"tmux select-window -t @{window.Id}", _lifetime.Token);
        _session = selected.Id;
    }

    private async Task ShowShellAsync()
    {
        if (_session is null) { _dismiss(); return; }
        await DetachAsync();
        _dismiss();
    }

    private async Task<string?> NameAsync(string title, string initial, string verb)
    {
        var field = new TextBox { Header = "Name", Text = initial, MinWidth = 260 };
        field.Loaded += (_, _) => { field.Focus(FocusState.Programmatic); field.SelectAll(); };
        if (await Alerts.ContentAsync(title, field, verb, null, _panel.ActualTheme, _ => { }) != ContentDialogResult.Primary) return null;
        return string.IsNullOrWhiteSpace(field.Text) ? null : field.Text.Trim();
    }

    private async Task CreateAsync()
    {
        if (await NameAsync("New Session", "", "Create") is not { } name) return;
        var directory = await _tab.Model.ResolveWorkingDirectoryAsync(_lifetime.Token);
        var created = await _tab.Model.CreateTmuxAsync(name, directory, _lifetime.Token);
        await RefreshAsync();
        await OpenAsync(created, null);
        _dismiss();
    }

    private async Task RenameSessionAsync(TmuxSessionInfo session)
    {
        if (await NameAsync("Rename", session.Name, "Save") is not { } name) return;
        await _tab.Model.RenameTmuxAsync(session.Id, name);
        await RefreshAsync();
    }

    private async Task RenameWindowAsync(TmuxWindow window)
    {
        if (await NameAsync("Rename", window.Name, "Save") is not { } name) return;
        await _tab.Model.ExecuteAsync("tmux rename-window -t @" + window.Id + " " + Quote(name), _lifetime.Token);
        await RefreshAsync();
    }

    private async Task ConfirmEndSession(TmuxSessionInfo session)
    {
        if (await Alerts.ContentAsync("End this session?", session.Name, "End", null, _panel.ActualTheme, _ => { }) != ContentDialogResult.Primary) return;
        if (_opened == session.Id) _opened = null;
        await _tab.Model.EndTmuxAsync(session.Id);
        if (_session == session.Id) _session = null;
        await RefreshAsync();
    }

    private async Task ConfirmEndWindow(TmuxWindow window)
    {
        if (await Alerts.ContentAsync("End this window?", window.Name, "End", null, _panel.ActualTheme, _ => { }) != ContentDialogResult.Primary) return;
        await _tab.Model.ExecuteAsync("tmux kill-window -t @" + window.Id, _lifetime.Token);
        await RefreshAsync();
    }

    private async Task DetachAsync()
    {
        if (_tty is null) throw new IOException("Unable to identify this terminal.");
        await _tab.Model.ExecuteAsync("tmux detach-client -t " + Quote(_tty), _lifetime.Token);
        _session = null;
    }

    private Task PerformAsync(string command) => RunAsync(async () =>
    {
        if (_session is null) await RefreshAsync();
        if (_session is null) throw new IOException("Attach to a tmux session first.");
        await _tab.Model.ExecuteAsync("tmux " + command + " -t " + SessionId(_session), _lifetime.Token);
    });

    private static string SessionId(string id) => id.Length is > 1 and < 21 && id[0] == '$' && id[1..].All(char.IsAsciiDigit)
        ? Quote(id) : throw new IOException("Invalid session identifier.");
    private static string Quote(string value) => !value.Any(char.IsControl) ? "'" + value.Replace("'", "'\\''") + "'" : throw new IOException("Invalid tmux name.");

    public ValueTask DisposeAsync()
    {
        _tab.Model.SessionChanged -= SessionChanged;
        _lifetime.Cancel();
        return ValueTask.CompletedTask;
    }
}
