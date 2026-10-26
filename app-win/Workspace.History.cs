namespace TetherApp;

public sealed partial class Workspace
{
    private ClosedTerminal RecordPane(TerminalPane tab, int index) => new(tab.Id, tab.Title, tab.Model.LocalProfile,
        tab.Model.WorkingDirectory, tab.Model.RemoteHost?.Alias, tab.Model.RemoteHost?.Target, index, tab.OpenInspector, tab.AttachmentStates, Fingerprint(tab.Model.RemoteHost), tab.Model.WslDistribution,
        PinnedName: tab.PinnedName);
    private ClosedTerminal Record(Tab group, int index) => RecordPane(group.Focused, index) with
    {
        Id = group.Id, Title = group.Title, Layout = group.Layout,
        Panes = group.Panes.Select(p => RecordPane(p, index)).ToArray(), FocusedPane = group.FocusedPane,
        WorkspaceHostAlias = group.Host?.Alias ?? ""
    };
    private static string? Fingerprint(HostEntry? host) => host is null ? null :
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(System.Text.Json.JsonSerializer.Serialize(host))));
    public void Persist() => _historyStore.Save(_tabs.Select((tab, index) => Record(tab, index)), _closed);
    public async Task<(Tab Tab, HostEntry? Host)?> RestoreAsync(Func<TerminalPane, HostEntry, Task<bool>>? connect = null)
    {
        if (!CanRestore) return null;
        var version = SelectionVersion;
        _restoring = true;
        try
        {
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
                    host = _hosts().FirstOrDefault(h => h.Alias == saved.HostAlias && h.Target == saved.Target &&
                        (saved.Configuration is null || Fingerprint(h) == saved.Configuration));
                    if (host is null) throw new IOException("The saved host was removed or changed.");
                }
                var pane = new TerminalPane(saved.Id, restoring: true);
                prepared.Add(pane);
                pane.Model.SetPalette(CurrentPalette);
                foreach (var (id, state) in saved.Attachments ?? []) pane.PendingAttachments[id] = state;
                await pane.BindAsync(saved.Profile, saved.Directory, startShell: host is null, wslDistribution: saved.WslDistribution, requireShell: host is null);
                if (host is not null)
                {
                    pane.Model.Keep(host);
                    if (connect is null || !await connect(pane, host)) throw new OperationCanceledException("Session restoration was cancelled.");
                }
                pane.Title = saved.Title;
                pane.PinnedName = TerminalLabels.RestoredPin(saved.Title, saved.PinnedName);
                pane.OpenInspector = saved.Inspector;
            }
        }
        catch { foreach (var pane in prepared) await pane.DisposeAsync(); throw; }
        var selectedBeforeCommit = ActiveGroup;
        var group = new Tab(prepared[0], record.Id);
        group.Host = record.WorkspaceHostAlias is { } alias
            ? alias.Length == 0 ? null : prepared.Select(p => p.Model.RemoteHost).FirstOrDefault(h => h?.Alias == alias)
              ?? _hosts().FirstOrDefault(h => h.Alias == alias)
            : prepared[0].Model.RemoteHost;
        var parent = _tabs.FirstOrDefault(t => t.Id == record.ParentId);
        if (parent is not null)
        {
            var restored = prepared[0];
            var neighbor = parent.Layout.Leaves.Contains(record.Neighbor ?? Guid.Empty) ? record.Neighbor!.Value : parent.FocusedPane;
            parent.Panes.Add(restored);
            var neighbors = (record.NeighborPanes ?? [neighbor]).Where(parent.Layout.Leaves.Contains).ToHashSet();
            if (neighbors.Count == 0) neighbors.Add(parent.FocusedPane);
            parent.Layout = record.WasSplit == false ? parent.Layout.ReplacePane(parent.FocusedPane, restored.Id)
                : parent.Layout.RestoreBeside(neighbors, restored.Id, record.SplitVertical, record.SplitBefore, record.SplitRatio);
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
        if (version == SelectionVersion)
        {
            CurrentHost = group.Host;
            _active = _tabs.IndexOf(group);
            SelectionVersion++;
            RememberSelection();
        }
        else _active = selectedBeforeCommit is null ? -1 : _tabs.IndexOf(selectedBeforeCommit);
        _closed.Remove(record);
        Persist(); Changed?.Invoke();
        return (group, null);
        }
        finally { _restoring = false; Changed?.Invoke(); }
    }

}
