using Tether;
using TetherApp.Plugins;

namespace TetherApp;

/// <summary>One terminal pane: a session and the surface that draws it.</summary>
public sealed class TerminalPane : IAsyncDisposable
{
    public Guid Id { get; }
    public string? StartingDirectory { get; set; }
    public string? HistoryProblem { get; private set; }
    private SessionHistory? _history;
    public SessionModel Model { get; } = new();
    public TerminalControl Surface { get; }
    public string Title { get; set; } = "localhost";
    /// <summary>Rename Terminal. While set, activity does not change the chip.</summary>
    public string? PinnedName { get; set; }
    /// <summary>Foreground program for the chip. Nil while the shell is at its prompt.</summary>
    public string? ForegroundCommand { get; set; }
    /// <summary>Directory last reported for the chip.</summary>
    public string? LabelPath { get; set; }
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

    public Dictionary<string, string> AttachmentStates
    {
        get
        {
            var states = new Dictionary<string, string>(PendingAttachments);
            foreach (var (id, attachment) in _attached)
                if (attachment.RestorationState is { } state) states[id] = state;
            return states;
        }
    }
    public IEnumerable<ITabAttachment> Attachments => _attached.Values;
    public ITabAttachment? AttachmentFor(string id) => _attached.GetValueOrDefault(id);

    public async Task BindAsync(string? profile = null, string? directory = null, bool startShell = true, string? wslDistribution = null, bool requireShell = false)
    {
        StartingDirectory = directory;
        await Surface.BindAsync(Model);
        // Every other terminal on this machine opens a local shell first and
        // offers SSH as the other thing it can do. So does this one.
        var shell = profile ?? AppSettings.Current.Shell;
        Title = AppSettings.KnownShells.FirstOrDefault(profile => profile.Program == shell).Name ?? shell;
        if (startShell && !await Model.OpenLocalAsync(shell, directory: directory, wslDistribution: wslDistribution) && requireShell) throw new IOException(Model.LastError ?? Model.Status);
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
