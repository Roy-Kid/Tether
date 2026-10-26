using Tether;

namespace TetherApp;

// The production workspace runs unchanged. Only the session and WinUI boundary
// is replaced: tests never start a shell, read user configuration or open a window.
public sealed class TerminalPane(Guid? id = null, bool restoring = false) : IAsyncDisposable
{
    public Guid Id { get; } = id ?? Guid.NewGuid();
    public string Title { get; set; } = "Terminal";
    public string? PinnedName { get; set; }
    public string? ForegroundCommand { get; set; }
    public string? LabelPath { get; set; }
    public string? HistoryProblem => null;
    public IEnumerable<TetherApp.Plugins.ITabAttachment> Attachments => [];
    public string? OpenInspector { get; set; }
    public Dictionary<string, string> PendingAttachments { get; } = [];
    public Dictionary<string, string> AttachmentStates => new(PendingAttachments);
    public SessionModel Model { get; } = new();
    public bool Disposed { get; private set; }
    public Task BindAsync(string? profile = null, string? directory = null, bool startShell = true,
        string? wslDistribution = null, bool requireShell = false)
    {
        Model.LocalProfile = profile ?? "cmd";
        Model.WorkingDirectory = directory;
        Model.WslDistribution = wslDistribution;
        return Task.CompletedTask;
    }
    public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
}

public sealed class SessionModel
{
    public HostEntry? RemoteHost { get; private set; }
    public string LocalProfile { get; set; } = "cmd";
    public string? WorkingDirectory { get; set; }
    public string? WslDistribution { get; set; }
    public bool IsLive => false;
    public bool IsWsl => false;
    public bool IsRemote => RemoteHost is not null;
    public uint? LocalProcessId => null;
    public event Action? SessionChanged { add { } remove { } }
    public void SetPalette(Palette palette) { }
    public void Keep(HostEntry host) => RemoteHost = host;
    public void CheckpointHistory() { }
    public Task<string?> ResolveWorkingDirectoryAsync(CancellationToken token) => Task.FromResult(WorkingDirectory);
}

public sealed class ExtensionTab : IAsyncDisposable
{
    public Guid Id { get; } = Guid.NewGuid();
    public string PluginId { get; }
    public HostEntry? Host { get; }
    public ExtensionTab(Plugins.ITabPlugin plugin, Plugins.ITabAttachment attachment, HostEntry? host, string? title = null)
    {
        PluginId = plugin.Metadata.Id;
        Host = host;
        _ = attachment;
        _ = title;
    }
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
