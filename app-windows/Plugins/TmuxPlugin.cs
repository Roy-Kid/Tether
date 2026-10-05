using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Tether;

namespace TetherApp.Plugins;

public sealed class TmuxPlugin : ITabPlugin
{
    public PluginMetadata Metadata { get; } = new("dev.tether.tmux", "tmux", "\uE8A7", "Sessions, windows and panes on the connected host.");
    public TabAccessory Accessory { get; } = new("\uE8A7", "tmux", AccessoryPlacement.Inspector);
    public IReadOnlyList<PluginCommandDescriptor> CommandDescriptors =>
    [new("newWindow", "New tmux Window"), new("splitHorizontal", "Split tmux Pane Horizontally"),
     new("splitVertical", "Split tmux Pane Vertically"), new("zoom", "Zoom tmux Pane"), new("detach", "Detach tmux")];
    public void Activate() { }
    public void Deactivate() { }
    public ITabAttachment Attach(TabContext tab) => new TmuxAttachment(tab);
}

sealed class TmuxAttachment : ITabAttachment
{
    private readonly TabContext _tab;
    private readonly StackPanel _panel = new() { Padding = new Thickness(12), Spacing = 8 };
    private readonly TextBox _query = new() { PlaceholderText = "Find a session…" };
    private readonly ListView _list = new() { MaxHeight = 400, IsItemClickEnabled = true };
    private readonly TextBlock _problem = new() { TextWrapping = TextWrapping.Wrap };
    private readonly CancellationTokenSource _lifetime = new();
    private IReadOnlyList<TmuxSessionInfo> _sessions = [];
    private string? _tty, _session, _pendingRestore;
    private bool _busy;

    public TmuxAttachment(TabContext tab)
    {
        _tab = tab;
        _panel.Children.Add(_query); _panel.Children.Add(_list); _panel.Children.Add(_problem);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        void Add(string glyph, string name, Func<Task> run)
        {
            var button = new Button { Content = glyph, FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Segoe Fluent Icons") };
            ToolTipService.SetToolTip(button, name); AutomationProperties.SetName(button, name);
            button.Click += async (_, _) => await RunAsync(run); buttons.Children.Add(button);
        }
        Add("\uE72C", "Refresh", RefreshAsync);
        Add("\uE710", "New Session", CreateAsync);
        Add("\uE8AC", "Rename Session", RenameAsync);
        Add("\uE74D", "End Session", EndAsync);
        Add("\uE8A7", "Detach", DetachAsync);
        _panel.Children.Add(buttons);
        _query.TextChanged += (_, _) => Render();
        _list.ItemClick += async (_, e) => { if (e.ClickedItem is Row row) await RunAsync(() => OpenAsync(row.Session, row.Window)); };
        _query.KeyDown += async (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; _tab.Dismiss(); }
            else if (e.Key == Windows.System.VirtualKey.Enter && _list.SelectedItem is Row row) { e.Handled = true; await RunAsync(() => OpenAsync(row.Session, row.Window)); }
            else if (e.Key is Windows.System.VirtualKey.Down or Windows.System.VirtualKey.Up && _list.Items.Count > 0)
            { e.Handled = true; _list.SelectedIndex = Math.Clamp(_list.SelectedIndex + (e.Key == Windows.System.VirtualKey.Down ? 1 : -1), 0, _list.Items.Count - 1); _list.ScrollIntoView(_list.SelectedItem); }
        };
        _tab.Model.SessionChanged += SessionChanged;
    }

    public UIElement View => _panel;
    public string? CloseNote => _busy ? "A tmux operation stops." : null;
    public string? RestorationState => _session;
    public IReadOnlyList<PluginCommand> Commands =>
    [
        new("newWindow", "New tmux Window", () => PerformAsync("new-window")),
        new("splitHorizontal", "Split tmux Pane Horizontally", () => PerformAsync("split-window -h")),
        new("splitVertical", "Split tmux Pane Vertically", () => PerformAsync("split-window -v")),
        new("zoom", "Zoom tmux Pane", () => PerformAsync("resize-pane -Z")),
        new("detach", "Detach tmux", () => RunAsync(DetachAsync)),
    ];
    public Task RestoreAsync(string state) { _pendingRestore = state; return Task.CompletedTask; }
    public Task ShownAsync() => RunAsync(RefreshAsync);
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
        _busy = true; _problem.Text = "";
        try { await action(); }
        catch (OperationCanceledException) { }
        catch (Exception ex) { _problem.Text = ex.Message; }
        finally { _busy = false; }
    }
    private async Task RefreshAsync()
    {
        if (!_tab.Model.IsRemote || !_tab.Model.IsLive) throw new IOException("Connect to a host with tmux.");
        _sessions = await _tab.Model.TmuxSessionsAsync(_lifetime.Token);
        _tty = await ShellTTY.FindAsync(_tab.Model, _lifetime.Token);
        _session = _tty is null ? null : await _tab.Model.TmuxSessionForClientAsync(_tty);
        Render();
        if (_pendingRestore is { } id && _sessions.FirstOrDefault(s => s.Id == id) is { } saved)
        { _pendingRestore = null; await OpenAsync(saved, null); }
    }
    private sealed record Row(TmuxSessionInfo Session, TmuxWindow? Window)
    {
        public override string ToString() => Window is null ? Session.Name : $"    {Window.Index}: {Window.Name}";
    }
    private void Render()
    {
        var rows = new List<Row>();
        foreach (var session in _sessions.Where(s => (s.Name + " " + string.Join(" ", s.Windows.Select(w => w.Name))).Contains(_query.Text, StringComparison.OrdinalIgnoreCase)))
        {
            rows.Add(new(session, null));
            rows.AddRange(session.Windows.Select(w => new Row(session, w)));
        }
        _list.ItemsSource = rows;
        _list.SelectedIndex = rows.Count > 0 ? 0 : -1;
    }
    private async Task OpenAsync(TmuxSessionInfo selected, TmuxWindow? window)
    {
        if (_tty is null) throw new IOException("Unable to identify this terminal.");
        var target = SessionId(selected.Id);
        var current = await _tab.Model.TmuxSessionForClientAsync(_tty);
        if (current is not null)
            await _tab.Model.ExecuteAsync("tmux switch-client -c " + Quote(_tty) + " -t " + target, _lifetime.Token);
        else
        {
            // Clear a partially typed command before attaching in the shell.
            _tab.Model.Send(new TerminalInput.Key(new KeyPress.Char("u"), new KeyModifiers(Control: true)));
            _tab.Model.Send(new TerminalInput.Paste("tmux attach-session -t " + target));
            _tab.Model.Send(new TerminalInput.Key(new KeyPress.Enter(), new KeyModifiers()));
        }
        if (window is not null) await _tab.Model.ExecuteAsync($"tmux select-window -t @{window.Id}", _lifetime.Token);
        _session = selected.Id; _tab.Dismiss();
    }
    private async Task<string?> NameAsync(string title, string initial)
    {
        var field = new TextBox { Text = initial, MinWidth = 260 };
        field.Loaded += (_, _) => { field.Focus(FocusState.Programmatic); field.SelectAll(); };
        if (await Alerts.ContentAsync(title, field, "Save", null, _panel.ActualTheme, _ => { }) != ContentDialogResult.Primary) return null;
        return string.IsNullOrWhiteSpace(field.Text) ? null : field.Text.Trim();
    }
    private async Task CreateAsync()
    {
        if (await NameAsync("New Session", "") is not { } name) return;
        var created = await _tab.Model.CreateTmuxAsync(name, _tab.Model.WorkingDirectory, _lifetime.Token);
        await RefreshAsync(); await OpenAsync(created, null);
    }
    private async Task RenameAsync()
    {
        if (_list.SelectedItem is not Row row || await NameAsync("Rename Session", row.Session.Name) is not { } name) return;
        await _tab.Model.RenameTmuxAsync(row.Session.Id, name); await RefreshAsync();
    }
    private async Task EndAsync()
    {
        if (_list.SelectedItem is not Row row) return;
        if (await Alerts.ContentAsync("End Session?", row.Session.Name, "End", null, _panel.ActualTheme, _ => { }) != ContentDialogResult.Primary) return;
        await _tab.Model.EndTmuxAsync(row.Session.Id); await RefreshAsync();
    }
    private async Task DetachAsync()
    {
        if (_tty is null) throw new IOException("Unable to identify this terminal.");
        await _tab.Model.ExecuteAsync("tmux detach-client -t " + Quote(_tty), _lifetime.Token);
        _session = null; _tab.Dismiss();
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
        // Closing the tab drops this client's terminal; the server session survives.
        return ValueTask.CompletedTask;
    }
}
