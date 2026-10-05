// Tabs. One job per conversation; a tab is a session.
//
// A new tab starts the local profile selected in Settings.

using Tether;
using TetherApp.Plugins;

namespace TetherApp;

/// <summary>One tab: a session and the surface that draws it.</summary>
public sealed class Tab : IAsyncDisposable
{
    public Guid Id { get; }
    public string? HistoryProblem { get; private set; }
    private SessionHistory? _history;
    public SessionModel Model { get; } = new();
    public TerminalControl Surface { get; }
    public string Title { get; set; } = "localhost";
    /// <summary>Which inspector plugin this tab has open. Each tab keeps its own; a cluster's files are not another's.</summary>
    public string? OpenInspector { get; set; }
    public Dictionary<string, string> PendingAttachments { get; } = new();
    private readonly Dictionary<string, ITabAttachment> _attached = new();

    public Tab(Guid? id = null, bool restoring = false)
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
        await Surface.BindAsync(Model);
        // Every other terminal on this machine opens a local shell first and
        // offers SSH as the other thing it can do. So does this one.
        var shell = profile ?? AppSettings.Current.Shell;
        Title = AppSettings.KnownShells.FirstOrDefault(profile => profile.Program == shell).Name ?? shell;
        if (startShell) await Model.OpenLocalAsync(shell, directory: directory, wslDistribution: wslDistribution);
    }

    public async ValueTask DisposeAsync()
    {
        foreach (var attachment in _attached.Values) await attachment.DisposeAsync();
        _attached.Clear();
        await Model.DisposeAsync();
        _history?.Dispose();
        _history = null;
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
    public string? HistoryProblem => _historyStore.Problem ?? _tabs.Select(t => t.HistoryProblem).FirstOrDefault(p => p is not null);
    private ClosedTerminal Record(Tab tab, int index) => new(tab.Id, tab.Title, tab.Model.LocalProfile,
        tab.Model.WorkingDirectory, tab.Model.RemoteHost?.Alias, tab.Model.RemoteHost?.Target, index, tab.OpenInspector, tab.AttachmentStates, Fingerprint(tab.Model.RemoteHost), tab.Model.WslDistribution);
    private static string? Fingerprint(HostEntry? host) => host is null ? null :
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(System.Text.Json.JsonSerializer.Serialize(host))));
    public void Persist() => _historyStore.Save(_tabs.Select((tab, index) => Record(tab, index)), _closed);
    public void Rename(Tab tab, string title) { tab.Title = title; Persist(); Changed?.Invoke(); }

    public async Task<(Tab Tab, HostEntry? Host)?> RestoreAsync()
    {
        if (!CanRestore) return null;
        var record = _closed[^1];
        HostEntry? host = null;
        if (record.HostAlias is not null)
        {
            // Use current config, never archived credentials or an obsolete target.
            host = SshConfig.Load().FirstOrDefault(h => h.Alias == record.HostAlias && h.Target == record.Target && (record.Configuration is null || Fingerprint(h) == record.Configuration));
            if (host is null) throw new IOException("The saved host was removed or changed.");
        }
        var tab = new Tab(record.Id, restoring: true);
        tab.Model.SetPalette(CurrentPalette);
        if (host is not null) tab.Model.Keep(host);
        foreach (var (id, state) in record.Attachments ?? []) tab.PendingAttachments[id] = state;
        tab.Model.SessionChanged += NotifySessionChanged;
        _tabs.Insert(Math.Clamp(record.Index, 0, _tabs.Count), tab);
        _active = _tabs.IndexOf(tab);
        try { await tab.BindAsync(record.Profile, record.Directory, startShell: host is null, wslDistribution: record.WslDistribution); }
        catch
        {
            tab.Model.SessionChanged -= NotifySessionChanged;
            _tabs.Remove(tab);
            _active = Math.Clamp(_active, 0, Math.Max(0, _tabs.Count - 1));
            await tab.DisposeAsync();
            Changed?.Invoke();
            throw;
        }
        tab.Title = record.Title;
        tab.OpenInspector = record.Inspector;
        _closed.RemoveAt(_closed.Count - 1);
        Persist(); Changed?.Invoke();
        return (tab, host);
    }

    public IReadOnlyList<Tab> Tabs => _tabs;
    public Palette CurrentPalette { get; set; } = Palette.Dark;
    public int ActiveIndex => _active;
    public Tab? Active => _tabs.Count == 0 ? null : _tabs[Math.Clamp(_active, 0, _tabs.Count - 1)];

    /// <summary>Raised when the tab list or the active tab changes.</summary>
    public event Action? Changed;

    public async Task<Tab> AddAsync()
    {
        var tab = new Tab();
        tab.Model.SetPalette(CurrentPalette);
        tab.Model.SessionChanged += NotifySessionChanged;
        _tabs.Add(tab);
        _active = _tabs.Count - 1;
        await tab.BindAsync();
        Persist();
        Changed?.Invoke();
        return tab;
    }

    public async Task CloseAsync(int index)
    {
        if (index < 0 || index >= _tabs.Count) return;
        var tab = _tabs[index];
        tab.Model.CheckpointHistory();
        _closed.Add(Record(tab, index));
        if (_closed.Count > 20) _closed.RemoveAt(0);
        tab.Model.SessionChanged -= NotifySessionChanged;
        _tabs.RemoveAt(index);
        if (index < _active) _active--;
        if (_active >= _tabs.Count) _active = _tabs.Count - 1;
        await tab.DisposeAsync();
        Persist();
        Changed?.Invoke();
    }

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
        foreach (var tab in _tabs) await tab.DisposeAsync();
        _tabs.Clear();
    }
}
