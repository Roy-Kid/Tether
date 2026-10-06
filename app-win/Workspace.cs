// Tabs. One job per conversation; a tab is a session.
//
// A new tab starts the local profile selected in Settings.

using Tether;
using TetherApp.Plugins;

namespace TetherApp;

/// <summary>One tab: a session and the surface that draws it.</summary>
public sealed class TerminalPane : IAsyncDisposable
{
    public Guid Id { get; }
    public string? StartingDirectory { get; set; }
    public string? HistoryProblem { get; private set; }
    private SessionHistory? _history;
    public SessionModel Model { get; } = new();
    public TerminalControl Surface { get; }
    public string Title { get; set; } = "localhost";
    /// <summary>Which inspector plugin this tab has open. Each tab keeps its own; a cluster's files are not another's.</summary>
    public string? OpenInspector { get; set; }
    public Dictionary<string, string> PendingAttachments { get; } = new();
    private readonly Dictionary<string, ITabAttachment> _attached = new();

    public TerminalPane(Guid? id = null, bool restoring = false)
    {
        Id = id ?? Guid.NewGuid();
        try
        {
            Directory.CreateDirectory(SessionHistoryStore.Root);
            _history = new SessionHistory(SessionHistoryStore.Location(Id),
                AppSettings.Current.UnlimitedHistory ? null : Math.Max(1UL, AppSettings.Current.HistoryLines), restoring);
            Model.History = _history;
        }
        catch (Exception ex) { HistoryProblem = ex.Message; }
        Surface = new TerminalControl();
    }

    /// <summary>The plugin's attachment for this tab, created the first time it is needed.</summary>
    public ITabAttachment Attach(ITabPlugin plugin, TabContext context)
    {
        if (_attached.TryGetValue(plugin.Metadata.Id, out var existing)) return existing;
        var created = plugin.Attach(context);
        _attached[plugin.Metadata.Id] = created;
        if (PendingAttachments.Remove(plugin.Metadata.Id, out var saved)) _ = created.RestoreAsync(saved);
        return created;
    }

    public async Task DetachAsync(string id)
    {
        if (!_attached.Remove(id, out var attachment)) return;
        await attachment.DisposeAsync();
    }

    public Dictionary<string, string> AttachmentStates => _attached.Where(p => p.Value.RestorationState is not null)
        .ToDictionary(p => p.Key, p => p.Value.RestorationState!);
    public IEnumerable<ITabAttachment> Attachments => _attached.Values;

    public async Task BindAsync(string? profile = null, string? directory = null, bool startShell = true, string? wslDistribution = null)
    {
        StartingDirectory = directory;
        await Surface.BindAsync(Model);
        // Every other terminal on this machine opens a local shell first and
        // offers SSH as the other thing it can do. So does this one.
        var shell = profile ?? AppSettings.Current.Shell;
        Title = AppSettings.KnownShells.FirstOrDefault(profile => profile.Program == shell).Name ?? shell;
        if (startShell && !await Model.OpenLocalAsync(shell, directory: directory, wslDistribution: wslDistribution)) throw new IOException(Model.Status);
    }

    public async ValueTask DisposeAsync()
    {
        foreach (var attachment in _attached.Values) await attachment.DisposeAsync();
        _attached.Clear();
        Surface.DisposeSurface();
        await Model.DisposeAsync();
        _history?.Dispose();
        _history = null;
    }
}

/// <summary>A named workspace. Session ownership belongs to its panes.</summary>
public sealed class Tab
{
    public Guid Id { get; }
    public string Title { get; set; }
    public SplitLayout Layout { get; set; }
    public List<TerminalPane> Panes { get; } = [];
    public Guid FocusedPane { get; set; }
    public bool Maximized { get; set; }
    public TerminalPane Focused => Panes.FirstOrDefault(p => p.Id == FocusedPane) ?? Panes[0];
    public Tab(TerminalPane pane, Guid? id = null)
    {
        Id = id ?? Guid.NewGuid();
        Title = pane.Title;
        Panes.Add(pane);
        Layout = SplitLayout.Leaf(pane.Id);
        FocusedPane = pane.Id;
    }
}

/// <summary>The tab set a window owns.</summary>
public sealed class Workspace : IAsyncDisposable
{
    private readonly List<Tab> _tabs = [];
    private int _active;
    private readonly SessionHistoryStore _historyStore = new();
    private readonly List<ClosedTerminal> _closed;
    public Workspace() => _closed = _historyStore.Load().ToList();
    public bool CanRestore => _closed.Count > 0;
    public string? HistoryProblem => _historyStore.Problem ?? AllPanes.Select(t => t.HistoryProblem).FirstOrDefault(p => p is not null);
    private ClosedTerminal RecordPane(TerminalPane tab, int index) => new(tab.Id, tab.Title, tab.Model.LocalProfile,
        tab.Model.WorkingDirectory, tab.Model.RemoteHost?.Alias, tab.Model.RemoteHost?.Target, index, tab.OpenInspector, tab.AttachmentStates, Fingerprint(tab.Model.RemoteHost), tab.Model.WslDistribution);
    private ClosedTerminal Record(Tab group, int index) => RecordPane(group.Focused, index) with
    {
        Id = group.Id, Title = group.Title, Layout = group.Layout,
        Panes = group.Panes.Select(p => RecordPane(p, index)).ToArray(), FocusedPane = group.FocusedPane
    };
    private static string? Fingerprint(HostEntry? host) => host is null ? null :
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(System.Text.Json.JsonSerializer.Serialize(host))));
    public void Persist() => _historyStore.Save(_tabs.Select((tab, index) => Record(tab, index)), _closed);
    public void Rename(Tab tab, string title) { tab.Title = title; Persist(); Changed?.Invoke(); }
    public void Rename(TerminalPane pane, string title) { if (_tabs.FirstOrDefault(t => t.Panes.Contains(pane)) is { } tab) Rename(tab, title); }

    public async Task<(Tab Tab, HostEntry? Host)?> RestoreAsync(Func<TerminalPane, HostEntry, Task<bool>>? connect = null)
    {
        if (!CanRestore) return null;
        var record = _closed[^1];
        var records = record.Panes ?? [record];
        var prepared = new List<TerminalPane>();
        try
        {
            foreach (var saved in records)
            {
                HostEntry? host = null;
                if (saved.HostAlias is not null)
                {
                    host = SshConfig.Load().FirstOrDefault(h => h.Alias == saved.HostAlias && h.Target == saved.Target &&
                        (saved.Configuration is null || Fingerprint(h) == saved.Configuration));
                    if (host is null) throw new IOException("The saved host was removed or changed.");
                }
                var pane = new TerminalPane(saved.Id, restoring: true);
                prepared.Add(pane);
                pane.Model.SetPalette(CurrentPalette);
                foreach (var (id, state) in saved.Attachments ?? []) pane.PendingAttachments[id] = state;
                await pane.BindAsync(saved.Profile, saved.Directory, startShell: host is null, wslDistribution: saved.WslDistribution);
                if (host is not null)
                {
                    pane.Model.Keep(host);
                    if (connect is null || !await connect(pane, host)) throw new OperationCanceledException("Session restoration was cancelled.");
                }
                pane.Title = saved.Title;
                pane.OpenInspector = saved.Inspector;
            }
        }
        catch { foreach (var pane in prepared) await pane.DisposeAsync(); throw; }
        var group = new Tab(prepared[0], record.Id);
        var parent = _tabs.FirstOrDefault(t => t.Id == record.ParentId);
        if (parent is not null)
        {
            var restored = prepared[0];
            var neighbor = parent.Layout.Leaves.Contains(record.Neighbor ?? Guid.Empty) ? record.Neighbor!.Value : parent.FocusedPane;
            parent.Panes.Add(restored);
            parent.Layout = parent.Layout.Split(neighbor, restored.Id, record.SplitVertical);
            parent.FocusedPane = restored.Id;
            group = parent;
            _active = _tabs.IndexOf(parent);
        }
        else
        {
            group.Panes.AddRange(prepared.Skip(1));
            group.Layout = record.Layout ?? SplitLayout.Leaf(prepared[0].Id);
            group.FocusedPane = record.FocusedPane ?? prepared[0].Id;
            group.Title = record.Title;
            _tabs.Insert(Math.Clamp(record.Index, 0, _tabs.Count), group);
            _active = _tabs.IndexOf(group);
        }
        foreach (var pane in prepared) pane.Model.SessionChanged += NotifySessionChanged;
        _closed.RemoveAt(_closed.Count - 1);
        Persist(); Changed?.Invoke();
        return (group, null);
    }

    public IReadOnlyList<Tab> Tabs => _tabs;
    public Palette CurrentPalette { get; set; } = Palette.Dark;
    public int ActiveIndex => _active;
    public Tab? ActiveGroup => _tabs.Count == 0 ? null : _tabs[Math.Clamp(_active, 0, _tabs.Count - 1)];
    public TerminalPane? Active => ActiveGroup?.Focused;
    public IEnumerable<TerminalPane> AllPanes => _tabs.SelectMany(t => t.Panes);
    public bool Contains(TerminalPane pane) => AllPanes.Contains(pane);
    public void Focus(TerminalPane pane)
    {
        var group = _tabs.FirstOrDefault(t => t.Panes.Contains(pane));
        if (group is null || group.FocusedPane == pane.Id) return;
        group.FocusedPane = pane.Id;
        Changed?.Invoke();
    }
    public async Task<TerminalPane?> SplitAsync(bool vertical)
    {
        if (ActiveGroup is not { } group || Active is not { } source) return null;
        var pane = new TerminalPane();
        pane.Model.SetPalette(CurrentPalette);
        try
        {
            await pane.BindAsync(source.Model.LocalProfile, await source.Model.ResolveWorkingDirectoryAsync(CancellationToken.None),
                startShell: source.Model.RemoteHost is null, wslDistribution: source.Model.WslDistribution);
            if (source.Model.RemoteHost is { } host) pane.Model.Keep(host);
        }
        catch { await pane.DisposeAsync(); throw; }
        if (!_tabs.Contains(group) || !group.Panes.Contains(source)) { await pane.DisposeAsync(); return null; }
        pane.Model.SessionChanged += NotifySessionChanged;
        group.Panes.Add(pane);
        group.Layout = group.Layout.Split(source.Id, pane.Id, vertical);
        group.FocusedPane = pane.Id;
        group.Maximized = false;
        Persist(); Changed?.Invoke();
        return pane;
    }

    /// <summary>Raised when the tab list or the active tab changes.</summary>
    public event Action? Changed;

    public async Task<TerminalPane> AddAsync()
    {
        var pane = new TerminalPane();
        pane.Model.SetPalette(CurrentPalette);
        try { await pane.BindAsync(); }
        catch { await pane.DisposeAsync(); throw; }
        pane.Model.SessionChanged += NotifySessionChanged;
        _tabs.Add(new Tab(pane));
        _active = _tabs.Count - 1;
        Persist(); Changed?.Invoke();
        return pane;
    }

    public async Task CloseAsync(int index, bool remember = true)
    {
        if (index < 0 || index >= _tabs.Count) return;
        var tab = _tabs[index];
        foreach (var pane in tab.Panes) pane.Model.CheckpointHistory();
        if (remember) _closed.Add(Record(tab, index));
        if (_closed.Count > 20) _closed.RemoveAt(0);
        _tabs.RemoveAt(index);
        if (index < _active) _active--;
        if (_active >= _tabs.Count) _active = _tabs.Count - 1;
        foreach (var pane in tab.Panes) { pane.Model.SessionChanged -= NotifySessionChanged; await pane.DisposeAsync(); }
        Persist();
        Changed?.Invoke();
    }

    public async Task ClosePaneAsync(TerminalPane pane, bool remember = true)
    {
        var group = _tabs.FirstOrDefault(t => t.Panes.Contains(pane));
        if (group is null) return;
        if (group.Layout.Leaves.Count() == 1) { await CloseAsync(_tabs.IndexOf(group), remember); return; }
        var parent = FindParent(group.Layout, pane.Id)!;
        var neighbor = (parent.First!.Leaves.Contains(pane.Id) ? parent.Second! : parent.First!).Leaves.First();
        if (remember)
        {
            pane.Model.CheckpointHistory();
            _closed.Add(RecordPane(pane, _tabs.IndexOf(group)) with { ParentId = group.Id, Neighbor = neighbor, SplitVertical = parent.Vertical });
            if (_closed.Count > 20) _closed.RemoveAt(0);
        }
        group.Layout = group.Layout.Remove(pane.Id)!;
        group.FocusedPane = neighbor;
        group.Maximized = false;
        pane.Model.SessionChanged -= NotifySessionChanged;
        await pane.DisposeAsync();
        group.Panes.Remove(pane);
        Persist(); Changed?.Invoke();
    }
    public async Task ReplacePaneAsync(TerminalPane source, TerminalPane replacement)
    {
        var group = _tabs.FirstOrDefault(t => t.Panes.Contains(source));
        if (group is null) { await replacement.DisposeAsync(); return; }
        group.Panes.Add(replacement);
        group.Layout = group.Layout.ReplacePane(source.Id, replacement.Id);
        group.FocusedPane = replacement.Id;
        replacement.Model.SessionChanged += NotifySessionChanged;
        source.Model.SessionChanged -= NotifySessionChanged;
        await source.DisposeAsync();
        group.Panes.Remove(source);
        if (group.Layout.Leaves.Count() == 1) group.Title = replacement.Title;
        Persist(); Changed?.Invoke();
    }

    private static SplitLayout? FindParent(SplitLayout node, Guid pane) => node.Pane is not null ? null :
        node.First!.Pane == pane || node.Second!.Pane == pane ? node : FindParent(node.First, pane) ?? FindParent(node.Second, pane);

    private void NotifySessionChanged() => Changed?.Invoke();

    public void Select(int index)
    {
        if (index < 0 || index >= _tabs.Count) return;
        _active = index;
        Changed?.Invoke();
    }

    public async ValueTask DisposeAsync()
    {
        Persist();
        foreach (var tab in AllPanes) await tab.DisposeAsync();
        _tabs.Clear();
    }
}
