using Tether;

namespace TetherApp;

/// <summary>The tab set a window owns.</summary>
public sealed partial class Workspace : IAsyncDisposable
{
    private readonly List<Tab> _tabs = [];
    private readonly List<ExtensionTab> _extensions = [];
    private int _active;
    private ExtensionTab? _activeExtension;
    private readonly SessionHistoryStore _historyStore;
    private readonly Func<IReadOnlyList<HostEntry>> _hosts;
    private readonly List<ClosedTerminal> _closed;
    private bool _restoring;
    private readonly Dictionary<string, Guid> _lastHostTab = [];
    public HostEntry? CurrentHost { get; private set; }
    public string CurrentHostLabel => CurrentHost?.Label ?? "localhost";
    public long SelectionVersion { get; private set; }
    // Alias+Target — not a full JSON fingerprint — so a host from a fresh
    // ssh config load still matches the tab opened from a previous pick.
    private static string HostKey(HostEntry? host) => host is null ? "local" : host.Alias + "\n" + host.Target;
    public IReadOnlyList<Tab> VisibleTabs => _tabs.Where(t => HostKey(t.Host) == HostKey(CurrentHost)).ToArray();
    /// <summary>One chip per terminal, in workspace order. A split does not hide its panes.</summary>
    public IReadOnlyList<TerminalPane> VisiblePanes => VisibleTabs.SelectMany(tab => tab.Panes).ToArray();
    public IReadOnlyList<ExtensionTab> Extensions => _extensions;
    public IReadOnlyList<ExtensionTab> VisibleExtensions => _extensions
        .Where(e => e.Host is null || HostKey(e.Host) == HostKey(CurrentHost)).ToArray();
    public ExtensionTab? ActiveExtension =>
        _activeExtension is { } extension && VisibleExtensions.Contains(extension) ? extension : null;
    public Workspace(SessionHistoryStore? historyStore = null, Func<IReadOnlyList<HostEntry>>? hosts = null)
    {
        _historyStore = historyStore ?? new SessionHistoryStore();
        _hosts = hosts ?? (() => SshConfig.Load());
        _closed = _historyStore.Load().ToList();
    }
    public bool CanRestore => _closed.Count > 0 && !_restoring;
    public string? HistoryProblem => _historyStore.Problem ?? AllPanes.Select(t => t.HistoryProblem).FirstOrDefault(p => p is not null);
    public void Rename(Tab tab, string title) { tab.Title = title; Persist(); Changed?.Invoke(); }
    public void Rename(TerminalPane pane, string title)
    {
        var trimmed = title.Trim();
        pane.PinnedName = trimmed.Length == 0 ? null : trimmed;
        pane.Title = trimmed.Length == 0 ? pane.Title : trimmed;
        Persist();
        Changed?.Invoke();
    }

    /// <summary>Chip text for a terminal, including twin numbers on the same host.</summary>
    public string DisplayTitle(TerminalPane pane)
    {
        RefreshLabels(pane);
        var host = pane.Model.RemoteHost;
        var peers = AllPanes.Where(candidate => SameHost(candidate.Model.RemoteHost, host)).ToArray();
        var home = host is null && !pane.Model.IsWsl ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) : null;
        var titles = TerminalLabels.Titles(peers.Select(peer => LabelFor(peer, home)).ToArray());
        return titles.GetValueOrDefault(pane.Id, pane.Title);
    }

    public string DisplayTitle(Tab tab) =>
        tab.Panes.Count == 1 ? DisplayTitle(tab.Focused) : tab.Title;

    public string RenameSeed(TerminalPane pane)
    {
        RefreshLabels(pane);
        var home = pane.Model.RemoteHost is null && !pane.Model.IsWsl
            ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) : null;
        return TerminalLabels.Seed(LabelFor(pane, home));
    }

    private static bool SameHost(HostEntry? left, HostEntry? right) =>
        left is null && right is null ||
        left is not null && right is not null && left.Alias == right.Alias && left.Target == right.Target;

    private static TerminalLabel LabelFor(TerminalPane pane, string? home)
    {
        var session = pane.Attachments
            .Select(attachment => attachment.TabTitle?.Trim())
            .FirstOrDefault(title => !string.IsNullOrEmpty(title));
        return new(pane.Id, pane.PinnedName, session, pane.ForegroundCommand, TerminalLabels.DirectoryName(pane.LabelPath ?? pane.Model.WorkingDirectory, home), pane.Title);
    }

    private static void RefreshLabels(TerminalPane pane)
    {
        if (!pane.Model.IsLive) return;
        pane.ForegroundCommand = pane.Model.IsRemote || pane.Model.IsWsl
            ? null
            : LocalForeground.Command(pane.Model.LocalProcessId);
        pane.LabelPath = pane.Model.WorkingDirectory;
    }

    public void SelectHost(HostEntry? host)
    {
        SelectionVersion++;
        RememberSelection();
        CurrentHost = host;
        _activeExtension = VisibleExtensions.FirstOrDefault(e => e.Id == _activeExtension?.Id);
        var visible = VisibleTabs;
        var remembered = _lastHostTab.GetValueOrDefault(HostKey(host));
        var next = visible.FirstOrDefault(t => t.Id == remembered) ?? visible.LastOrDefault();
        _active = next is null ? -1 : _tabs.IndexOf(next);
        Changed?.Invoke();
    }

    private void RememberSelection()
    {
        if (ActiveGroup is { } group) _lastHostTab[HostKey(group.Host)] = group.Id;
    }

    public void Activate(Tab group)
    {
        if (!_tabs.Contains(group)) return;
        SelectionVersion++;
        RememberSelection();
        CurrentHost = group.Host;
        _active = _tabs.IndexOf(group);
        _activeExtension = null;
        RememberSelection();
        Changed?.Invoke();
    }

    public void Activate(ExtensionTab extension)
    {
        if (!_extensions.Contains(extension)) return;
        SelectionVersion++;
        RememberSelection();
        if (extension.Host is not null) CurrentHost = extension.Host;
        _activeExtension = extension;
        Changed?.Invoke();
    }

    public ExtensionTab OpenExtension(Plugins.ITabPlugin plugin, Plugins.ITabAttachment attachment, HostEntry? host = null)
    {
        var existing = _extensions.FirstOrDefault(e => e.PluginId == plugin.Metadata.Id && HostKey(e.Host) == HostKey(host ?? CurrentHost));
        if (existing is not null)
        {
            _ = attachment.DisposeAsync();
            Activate(existing);
            return existing;
        }
        var extension = new ExtensionTab(plugin, attachment, host ?? CurrentHost);
        _extensions.Add(extension);
        Activate(extension);
        return extension;
    }

    public async Task CloseExtensionAsync(ExtensionTab extension)
    {
        if (!_extensions.Remove(extension)) return;
        if (_activeExtension == extension) _activeExtension = null;
        await extension.DisposeAsync();
        Changed?.Invoke();
    }

    public async Task CloseExtensionsForPluginAsync(string pluginId)
    {
        foreach (var extension in _extensions.Where(e => e.PluginId == pluginId).ToArray())
            await CloseExtensionAsync(extension);
    }

    public IReadOnlyList<Tab> Tabs => _tabs;
    public Palette CurrentPalette { get; set; } = Palette.Dark;
    public int ActiveIndex => ActiveExtension is not null ? -1
        : ActiveGroup is { } group ? VisibleTabs.ToList().IndexOf(group) : -1;
    public Tab? ActiveGroup => ActiveExtension is not null ? null
        : _active >= 0 && _active < _tabs.Count && HostKey(_tabs[_active].Host) == HostKey(CurrentHost) ? _tabs[_active] : null;
    public TerminalPane? Active => ActiveGroup?.Focused;
    public IEnumerable<TerminalPane> AllPanes => _tabs.SelectMany(t => t.Panes);
    public bool Contains(TerminalPane pane) => AllPanes.Contains(pane);
    public void Focus(TerminalPane pane)
    {
        var group = _tabs.FirstOrDefault(t => t.Panes.Contains(pane));
        if (group is null) return;
        if (group.FocusedPane == pane.Id && ActiveGroup == group) return;
        if (!group.Layout.Leaves.Contains(pane.Id))
            group.Layout = group.Layout.ReplacePane(group.FocusedPane, pane.Id);
        pane.OpenInspector = group.Focused.OpenInspector;
        group.FocusedPane = pane.Id;
        group.Maximized = false;
        Activate(group);
        Persist();
    }

    public void JoinSplits()
    {
        if (ActiveGroup is not { } group) return;
        group.Layout = SplitLayout.Leaf(group.FocusedPane);
        group.Maximized = false;
        Persist();
        Changed?.Invoke();
    }

    public void CycleTerminal(bool forward)
    {
        if (ActiveGroup is not { } group) return;
        var index = group.Panes.FindIndex(p => p.Id == group.FocusedPane);
        Focus(group.Panes[(index + (forward ? 1 : -1) + group.Panes.Count) % group.Panes.Count]);
    }

    public async Task<TerminalPane?> AddTerminalAsync(Func<TerminalPane, HostEntry, Task<bool>> connect)
    {
        if (ActiveGroup is not { } group) return await AddAsync(connect);
        var version = SelectionVersion;
        var source = group.Focused;
        var pane = await PrepareAsync(group.Host, connect, source);
        if (pane is null) return null;
        if (!_tabs.Contains(group)) { await pane.DisposeAsync(); return null; }
        pane.Model.SessionChanged += NotifySessionChanged;
        group.Panes.Add(pane);
        pane.OpenInspector = source.OpenInspector;
        // Replace only the visible terminal; all other shells stay owned.
        if (version == SelectionVersion)
        {
            group.Layout = group.Layout.ReplacePane(group.FocusedPane, pane.Id);
            group.FocusedPane = pane.Id;
            group.Maximized = false;
        }
        Persist(); Changed?.Invoke();
        return pane;
    }

    private async Task<TerminalPane?> PrepareAsync(HostEntry? host,
        Func<TerminalPane, HostEntry, Task<bool>>? connect, TerminalPane? source = null)
    {
        var pane = new TerminalPane();
        pane.Model.SetPalette(CurrentPalette);
        try
        {
            var directory = source is null ? null : await source.Model.ResolveWorkingDirectoryAsync(CancellationToken.None);
            await pane.BindAsync(source?.Model.LocalProfile, directory, startShell: host is null,
                wslDistribution: source?.Model.WslDistribution, requireShell: host is null);
            if (host is not null && (connect is null || !await connect(pane, host)))
            {
                await pane.DisposeAsync();
                return null;
            }
            pane.Title = $"Terminal {AllPanes.Count() + 1}";
            return pane;
        }
        catch { await pane.DisposeAsync(); throw; }
    }
    public Task<TerminalPane?> SplitAsync(bool vertical) => SplitAsync(vertical ? SplitEdge.Down : SplitEdge.Right);

    public async Task<TerminalPane?> SplitAsync(SplitEdge edge)
    {
        if (ActiveGroup is not { } group || Active is not { } source) return null;
        var pane = new TerminalPane();
        pane.Model.SetPalette(CurrentPalette);
        try
        {
            await pane.BindAsync(source.Model.LocalProfile, await source.Model.ResolveWorkingDirectoryAsync(CancellationToken.None),
                startShell: source.Model.RemoteHost is null, wslDistribution: source.Model.WslDistribution, requireShell: true);
            if (source.Model.RemoteHost is { } host) pane.Model.Keep(host);
        }
        catch { await pane.DisposeAsync(); throw; }
        if (!_tabs.Contains(group) || !group.Panes.Contains(source)) { await pane.DisposeAsync(); return null; }
        pane.OpenInspector = source.OpenInspector;
        pane.Model.SessionChanged += NotifySessionChanged;
        group.Panes.Add(pane);
        var vertical = edge is SplitEdge.Up or SplitEdge.Down;
        group.Layout = group.Layout.Split(source.Id, pane.Id, vertical, edge is SplitEdge.Left or SplitEdge.Up);
        group.FocusedPane = pane.Id;
        group.Maximized = false;
        Persist(); Changed?.Invoke();
        return pane;
    }

    /// <summary>Move an existing terminal onto one edge of another. Same host only.</summary>
    public bool Place(TerminalPane dragged, TerminalPane target, SplitEdge edge)
    {
        if (dragged == target) return false;
        var source = _tabs.FirstOrDefault(tab => tab.Panes.Contains(dragged));
        var destination = _tabs.FirstOrDefault(tab => tab.Panes.Contains(target));
        if (source is null || destination is null || !SameHost(source.Host, destination.Host)) return false;
        if (source == destination)
            source.Layout = SplitLayout.PlaceInLayout(source.Layout, dragged.Id, target.Id, edge);
        else
        {
            var rest = source.Layout.Remove(dragged.Id);
            source.Panes.Remove(dragged);
            if (source.Panes.Count == 0)
            {
                var index = _tabs.IndexOf(source);
                _tabs.RemoveAt(index);
                if (_active > index) _active--;
                else if (_active >= _tabs.Count) _active = _tabs.Count - 1;
            }
            else
            {
                source.Layout = rest ?? SplitLayout.Leaf(source.Panes[0].Id);
                if (!source.Layout.Leaves.Contains(source.FocusedPane))
                    source.FocusedPane = source.Layout.Leaves.First();
                source.Maximized = false;
            }
            destination.Panes.Add(dragged);
            destination.Layout = SplitLayout.InsertBeside(destination.Layout, target.Id, dragged.Id, edge);
        }
        destination.FocusedPane = dragged.Id;
        destination.Maximized = false;
        Persist();
        Activate(destination);
        return true;
    }

    /// <summary>Raised when the tab list or the active tab changes.</summary>
    public event Action? Changed;

    public async Task<TerminalPane?> AddAsync(Func<TerminalPane, HostEntry, Task<bool>>? connect = null)
    {
        var host = CurrentHost;
        var pane = await PrepareAsync(host, connect);
        if (pane is null) return null;
        pane.Model.SessionChanged += NotifySessionChanged;
        var tab = new Tab(pane) { Host = host ?? pane.Model.RemoteHost };
        _tabs.Add(tab);
        // Always land on the tab we just dialed. A focus steal from the local
        // shell while the auth dialog closes used to bump SelectionVersion and
        // leave this session orphaned under localhost.
        CurrentHost = tab.Host;
        _active = _tabs.IndexOf(tab);
        _activeExtension = null;
        SelectionVersion++;
        RememberSelection();
        Persist(); Changed?.Invoke();
        return pane;
    }

    public async Task CloseAsync(int index, bool remember = true)
    {
        var visible = VisibleTabs;
        if (index < 0 || index >= visible.Count) return;
        var tab = visible[index];
        var actualIndex = _tabs.IndexOf(tab);
        foreach (var pane in tab.Panes) pane.Model.CheckpointHistory();
        if (remember) _closed.Add(Record(tab, actualIndex));
        if (_closed.Count > 20) _closed.RemoveAt(0);
        var selected = ActiveGroup;
        _tabs.RemoveAt(actualIndex);
        var remaining = VisibleTabs;
        var next = selected != tab && selected is not null ? selected
            : remaining.ElementAtOrDefault(Math.Min(index, remaining.Count - 1));
        _active = next is null ? -1 : _tabs.IndexOf(next);
        foreach (var pane in tab.Panes) { pane.Model.SessionChanged -= NotifySessionChanged; await pane.DisposeAsync(); }
        Persist();
        Changed?.Invoke();
    }

    public async Task ClosePaneAsync(TerminalPane pane, bool remember = true)
    {
        var group = _tabs.FirstOrDefault(t => t.Panes.Contains(pane));
        if (group is null) return;
        if (group.Panes.Count == 1) { await CloseAsync(VisibleTabs.ToList().IndexOf(group), remember); return; }
        var parent = FindParent(group.Layout, pane.Id);
        var neighbor = parent is null ? group.Panes.First(p => p != pane).Id
            : (parent.First!.Leaves.Contains(pane.Id) ? parent.Second! : parent.First!).Leaves.First();
        if (remember)
        {
            pane.Model.CheckpointHistory();
            _closed.Add(RecordPane(pane, _tabs.IndexOf(group)) with { ParentId = group.Id, Neighbor = neighbor,
                SplitVertical = parent?.Vertical ?? false, SplitBefore = parent?.First?.Pane == pane.Id,
                SplitRatio = parent?.Ratio ?? .5,
                NeighborPanes = parent is null ? [neighbor] : (parent.First!.Pane == pane.Id ? parent.Second! : parent.First!).Leaves.ToArray(),
                WasSplit = parent is not null });
            if (_closed.Count > 20) _closed.RemoveAt(0);
        }
        group.Panes.First(p => p.Id == neighbor).OpenInspector = pane.OpenInspector;
        group.Layout = group.Layout.Remove(pane.Id) ?? SplitLayout.Leaf(neighbor);
        if (group.FocusedPane == pane.Id) group.FocusedPane = group.Layout.Leaves.Contains(neighbor) ? neighbor : group.Layout.Leaves.First();
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
        replacement.OpenInspector = source.OpenInspector;
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
        if (index < 0 || index >= VisibleTabs.Count) return;
        Activate(VisibleTabs[index]);
    }

    public async ValueTask DisposeAsync()
    {
        Persist();
        foreach (var extension in _extensions.ToArray()) await extension.DisposeAsync();
        _extensions.Clear();
        foreach (var tab in AllPanes) await tab.DisposeAsync();
        _tabs.Clear();
    }
}
