// Files, as a tab plugin: every terminal tab carries a browser of the
// machine its shell is running on, kept beside it.
//
// Registered once. The window learns the glyph and the name from the
// accessory, and never that this is the thing answering a path.

using Tether;

namespace TetherApp.Plugins;

public sealed class FilesPlugin : ITabPlugin
{
    public const string Id = "dev.tether.files";

    public PluginMetadata Metadata { get; } = new(Id, "Files", "\uE8B7", "Browse, open and move files where the shell is.");

    public TabAccessory Accessory { get; } = new("\uE8B7", "Files", AccessoryPlacement.Inspector);

    public void Activate() { }

    public void Deactivate() { }

    public ITabAttachment Attach(TabContext tab) => new FilesAttachment(tab);
}

sealed class FilesAttachment : ITabAttachment
{
    private readonly TabContext _tab;
    private readonly Files.FilesPane _pane;

    public FilesAttachment(TabContext tab)
    {
        _tab = tab;
        _pane = new Files.FilesPane(tab.Model);
        _pane.HideRequested += tab.Dismiss;
        _pane.OverlayChanged += tab.Overlay;
        _pane.DialogRoot = tab.DialogRoot;
        _pane.WindowHandle = tab.WindowHandle();
    }

    public Microsoft.UI.Xaml.UIElement View => _pane;

    public string? CloseNote => _pane.HasWork ? "A transfer stops." : null;

    public Task ShownAsync()
    {
        _pane.WindowHandle = _tab.WindowHandle();
        _pane.DialogRoot = _tab.DialogRoot;
        return _pane.ShowAsync();
    }

    public bool Receive(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return false;
        // On this machine a drop is a path to type. A remote shell, and WSL,
        // cannot see a Windows path, so the file has to be put where the
        // shell is and the path it will know typed after it (Decisions/0014).
        if (!_tab.Model.IsRemote && !_tab.Model.IsWsl) return false;
        _tab.Show();
        _ = ReceiveAsync(paths);
        return true;
    }

    private async Task ReceiveAsync(IReadOnlyList<string> paths)
    {
        try
        {
            var sent = await _pane.AcceptDropAsync(paths);
            if (sent.Count == 0) return;
            _tab.InsertText(string.Join(" ", sent) + " ");
        }
        catch (Exception ex)
        {
            _pane.Report(ex.Message);
        }
    }

    public LinkActions? ActionsFor(TerminalLink link)
    {
        var printed = link.Kind switch
        {
            LinkKind.Path path => path.Location,
            LinkKind.Hyperlink hyperlink => Files.FilesPaths.FileUri(hyperlink.Uri),
            _ => null,
        };
        if (printed is null) return null;
        return new LinkActions
        {
            Exists = token => _pane.ExistsPrintedAsync(printed, _tab.WorkingDirectory(), token),
            Open = async token =>
            {
                _tab.Show();
                await _pane.OpenPrintedAsync(printed, _tab.WorkingDirectory(), token);
            },
            Commands =
            [
                ("Show in Files", async token =>
                {
                    _tab.Show();
                    await _pane.RevealPrintedAsync(printed, _tab.WorkingDirectory(), token);
                }),
            ],
        };
    }

    public async ValueTask DisposeAsync()
    {
        _pane.HideRequested -= _tab.Dismiss;
        _pane.OverlayChanged -= _tab.Overlay;
        await _pane.DisposeAsync();
    }
}
