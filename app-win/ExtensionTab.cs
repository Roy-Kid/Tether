using Microsoft.UI.Xaml;
using TetherApp.Plugins;

namespace TetherApp;

/// <summary>
/// A plugin workspace that stands in for a terminal tab — the Windows shape of
/// macOS <c>PluginWorkspace</c> / <c>TabSet.extensions</c>.
/// </summary>
public sealed class ExtensionTab : IAsyncDisposable
{
    public Guid Id { get; } = Guid.NewGuid();
    public string PluginId { get; }
    public string Title { get; set; }
    public string Subtitle { get; }
    public string Glyph { get; }
    public HostEntry? Host { get; }
    public ITabAttachment Attachment { get; }
    public UIElement View => Attachment.View;

    public ExtensionTab(ITabPlugin plugin, ITabAttachment attachment, HostEntry? host, string? title = null)
    {
        PluginId = plugin.Metadata.Id;
        Title = title ?? plugin.Metadata.Name;
        Subtitle = plugin.Metadata.Summary;
        Glyph = plugin.Metadata.Glyph;
        Host = host;
        Attachment = attachment;
    }

    public ValueTask DisposeAsync() => Attachment.DisposeAsync();
}
