namespace TetherApp.Plugins;

public sealed class PluginMetadata
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    public string Summary { get; init; } = "";
}

public interface ITabPlugin
{
    PluginMetadata Metadata { get; }
}

public interface ITabAttachment : IAsyncDisposable
{
    string? TabTitle { get; }
}
