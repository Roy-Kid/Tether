// A tab plugin, as the window holds it.
//
// Two shapes on Mac; Windows has the one the file browser is. An inspector
// plugin sits beside the terminal while the shell keeps running
// (Decisions/0014). The host asks what to draw and forwards drops and
// links. It does not learn what a file is.

using Microsoft.UI.Xaml;
using Tether;

namespace TetherApp.Plugins;

public enum AccessoryPlacement { Inspector }

public sealed record TabAccessory(string Glyph, string Name, AccessoryPlacement Placement);

/// <summary>What a plugin offers for something a person pointed at.</summary>
public sealed class LinkActions
{
    public Func<CancellationToken, Task<bool>>? Exists { get; init; }
    public Func<CancellationToken, Task>? Open { get; init; }
    public IReadOnlyList<(string Title, Func<CancellationToken, Task> Run)> Commands { get; init; } = [];
}

/// <summary>One terminal tab, as a plugin attached to it sees it.</summary>
public sealed class TabContext
{
    public required SessionModel Model { get; init; }
    public required Action<string> InsertText { get; init; }
    public required Func<string?> WorkingDirectory { get; init; }
    public required Action Show { get; init; }
    public required Action Dismiss { get; init; }
    public required Func<nint> WindowHandle { get; init; }
    public required Func<XamlRoot?> DialogRoot { get; init; }
    public required Action<bool> Overlay { get; init; }
}

public interface ITabAttachment : IAsyncDisposable
{
    UIElement View { get; }
    /// <summary>One line under a close confirmation, when closing would stop work.</summary>
    string? CloseNote { get; }
    Task ShownAsync();
    /// <summary>Files dropped on the tab. <c>true</c> takes them.</summary>
    bool Receive(IReadOnlyList<string> paths);
    LinkActions? ActionsFor(TerminalLink link);
}

public interface ITabPlugin : ITetherPlugin
{
    TabAccessory Accessory { get; }
    ITabAttachment Attach(TabContext tab);
}
