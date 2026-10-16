using TetherApp;

var directory = Path.Combine(Path.GetTempPath(), "tether-workspace-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(directory);
var host = new HostEntry("lab", "lab.example", "ada", 22, null);
IReadOnlyList<HostEntry> hosts = [host];
Task<bool> Connect(TerminalPane pane, HostEntry target) { pane.Model.Keep(target); return Task.FromResult(true); }
Workspace Create(string name) => new(new SessionHistoryStore(Path.Combine(directory, name)), () => hosts);

try
{
    await using (var workspace = Create("navigation"))
    {
        var local = await workspace.AddAsync() ?? throw new Exception("No local terminal");
        var localTab = workspace.ActiveGroup!;
        workspace.SelectHost(host);
        Check(workspace.Active is null && workspace.VisibleTabs.Count == 0, "unvisited host starts empty");
        var remote = await workspace.AddAsync(Connect) ?? throw new Exception("No remote terminal");
        var remoteTab = workspace.ActiveGroup!;
        workspace.SelectHost(null);
        Check(workspace.Active == local && !remote.Disposed, "switching host preserves the previous shell");
        workspace.SelectHost(host);
        Check(workspace.Active == remote, "returning to a host restores its active terminal");
        var extra = await workspace.AddTerminalAsync(Connect) ?? throw new Exception("No extra terminal");
        Check(workspace.Tabs.Count == 2 && remoteTab.Panes.Count == 2 && !remote.Disposed, "New Terminal stays inside its workspace");
        Check(remoteTab.Layout.Leaves.SequenceEqual([extra.Id]), "new terminal replaces the visible leaf without ending its predecessor");
        workspace.Rename(extra, "build");
        Check(extra.Title == "build" && remoteTab.Title != "build", "terminal and workspace names are independent");
        workspace.CycleTerminal(false);
        Check(workspace.Active == remote && remoteTab.Layout.Leaves.SequenceEqual([remote.Id]), "hidden terminal can be selected again");
        var split = await workspace.SplitAsync(false) ?? throw new Exception("No split");
        Check(remoteTab.Layout.Leaves.Count() == 2, "split displays a second terminal");
        workspace.JoinSplits();
        Check(remoteTab.Layout.Leaves.Count() == 1 && remoteTab.Panes.Count == 3 && !split.Disposed, "joining splits keeps every session owned");
        workspace.Focus(extra);
        await workspace.ClosePaneAsync(extra);
        Check(extra.Disposed && !remote.Disposed && !split.Disposed, "closing a terminal leaves companions alive");
        await workspace.RestoreAsync(Connect);
        Check(remoteTab.Panes.Count == 3 && remoteTab.Layout.Leaves.Count() == 1, "reopening an unsplit terminal retains the unsplit presentation");
        await workspace.CloseAsync(workspace.ActiveIndex);
        Check(workspace.Active is null && workspace.CurrentHost == host && workspace.VisibleTabs.Count == 0,
            "closing the last host tab stays empty on that host");
        Check(!local.Disposed, "other hosts survive closing the current host's last tab");
        workspace.Activate(localTab);
        Check(workspace.Active == local, "a cross-host quick switch activates the requested workspace");
    }

    await using (var workspace = Create("late"))
    {
        var local = await workspace.AddAsync();
        workspace.SelectHost(host);
        var gate = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        async Task<bool> Delayed(TerminalPane pane, HostEntry target) { pane.Model.Keep(target); return await gate.Task; }
        var pending = workspace.AddAsync(Delayed);
        workspace.SelectHost(null);
        gate.SetResult(true);
        var remote = await pending;
        Check(workspace.Active == local && workspace.CurrentHost is null && remote is not null && !remote.Disposed,
            "late connection completion cannot steal another host's focus");
        workspace.SelectHost(host);
        Check(workspace.Active == remote, "completed background connection remains available");
    }

    await using (var workspace = Create("cancel"))
    {
        workspace.SelectHost(host);
        TerminalPane? attempt = null;
        await workspace.AddAsync((pane, _) => { attempt = pane; return Task.FromResult(false); });
        Check(workspace.Tabs.Count == 0 && attempt?.Disposed == true, "cancelled authentication leaves no orphan terminal");
    }

    var historyPath = "persistence";
    await using (var workspace = Create(historyPath))
    {
        var first = await workspace.AddAsync();
        first!.PendingAttachments["plugin.example"] = "kept";
        await workspace.AddTerminalAsync(Connect);
        workspace.JoinSplits();
        workspace.Persist();
    }
    await using (var restored = Create(historyPath))
    {
        await restored.RestoreAsync(Connect);
        Check(restored.ActiveGroup?.Panes.Count == 2 && restored.ActiveGroup.Layout.Leaves.Count() == 1,
            "restart restores hidden terminals without inventing splits");
        Check(restored.ActiveGroup.Panes.Any(p => p.PendingAttachments.GetValueOrDefault("plugin.example") == "kept"),
            "deferred plugin state survives the workspace migration");
    }
    Console.WriteLine("PASS: host navigation, terminal/tab ownership, split/join, late completion, cancellation and version-3 restoration.");
}
finally { Directory.Delete(directory, true); }

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
