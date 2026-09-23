// Tabs. One job per conversation; a tab is a session.
//
// The strip is icon-only with the host name on hover (law app-ui-chrome).
// The workspace is the same shape `WorkspaceView.swift` keeps on Apple.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tether;

namespace TetherApp;

/// <summary>One tab: a session and the surface that draws it.</summary>
public sealed class Tab : IAsyncDisposable
{
    public SessionModel Model { get; } = new();
    public TerminalControl Surface { get; }
    public string Title { get; set; } = "localhost";

    public Tab()
    {
        Surface = new TerminalControl();
    }

    public async Task BindAsync()
    {
        await Surface.BindAsync(Model);
        // Every other terminal on this machine opens a local shell first and
        // offers SSH as the other thing it can do. So does this one.
        if (AppSettings.Current.OpenLocalOnStart)
        {
            await Model.OpenLocalAsync(AppSettings.Current.Shell);
        }
    }

    public async ValueTask DisposeAsync()
    {
        await Model.DisposeAsync();
    }
}

/// <summary>The tab set a window owns.</summary>
public sealed class Workspace : IAsyncDisposable
{
    private readonly List<Tab> _tabs = [];
    private int _active;

    public IReadOnlyList<Tab> Tabs => _tabs;
    public int ActiveIndex => _active;
    public Tab? Active => _tabs.Count == 0 ? null : _tabs[Math.Clamp(_active, 0, _tabs.Count - 1)];

    /// <summary>Raised when the tab list or the active tab changes.</summary>
    public event Action? Changed;

    public async Task<Tab> AddAsync()
    {
        var tab = new Tab();
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
        _tabs.RemoveAt(index);
        await tab.DisposeAsync();
        if (_active >= _tabs.Count) _active = _tabs.Count - 1;
        Changed?.Invoke();
    }

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
