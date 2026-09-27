// Tabs. One job per conversation; a tab is a session.
//
// A new tab starts the local profile selected in Settings.

using Tether;
using TetherApp.Plugins;

namespace TetherApp;

/// <summary>One tab: a session and the surface that draws it.</summary>
public sealed class Tab : IAsyncDisposable
{
    public SessionModel Model { get; } = new();
    public TerminalControl Surface { get; }
    public string Title { get; set; } = "localhost";
    /// <summary>Which inspector plugin this tab has open. Each tab keeps its own; a cluster's files are not another's.</summary>
    public string? OpenInspector { get; set; }
    private readonly Dictionary<string, ITabAttachment> _attached = new();

    public Tab()
    {
        Surface = new TerminalControl();
    }

    /// <summary>The plugin's attachment for this tab, created the first time it is needed.</summary>
    public ITabAttachment Attach(ITabPlugin plugin, TabContext context)
    {
        if (_attached.TryGetValue(plugin.Metadata.Id, out var existing)) return existing;
        var created = plugin.Attach(context);
        _attached[plugin.Metadata.Id] = created;
        return created;
    }

    public async Task DetachAsync(string id)
    {
        if (!_attached.Remove(id, out var attachment)) return;
        await attachment.DisposeAsync();
    }

    public IEnumerable<ITabAttachment> Attachments => _attached.Values;

    public async Task BindAsync()
    {
        await Surface.BindAsync(Model);
        // Every other terminal on this machine opens a local shell first and
        // offers SSH as the other thing it can do. So does this one.
        var shell = AppSettings.Current.Shell;
        Title = AppSettings.KnownShells.FirstOrDefault(profile => profile.Program == shell).Name ?? shell;
        await Model.OpenLocalAsync(shell);
    }

    public async ValueTask DisposeAsync()
    {
        foreach (var attachment in _attached.Values) await attachment.DisposeAsync();
        _attached.Clear();
        await Model.DisposeAsync();
    }
}

/// <summary>The tab set a window owns.</summary>
public sealed class Workspace : IAsyncDisposable
{
    private readonly List<Tab> _tabs = [];
    private int _active;

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
        Changed?.Invoke();
        return tab;
    }

    public async Task CloseAsync(int index)
    {
        if (index < 0 || index >= _tabs.Count) return;
        var tab = _tabs[index];
        tab.Model.SessionChanged -= NotifySessionChanged;
        _tabs.RemoveAt(index);
        if (index < _active) _active--;
        if (_active >= _tabs.Count) _active = _tabs.Count - 1;
        await tab.DisposeAsync();
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
        foreach (var tab in _tabs) await tab.DisposeAsync();
        _tabs.Clear();
    }
}
