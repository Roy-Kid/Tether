// Which extensions are installed, and which a person has turned off.
//
// The window draws what this lists. It does not know what an extension is
// for — the one line that names one is the registration, the same rule as
// on Mac (Decisions/0012).

namespace TetherApp.Plugins;

public sealed record PluginMetadata(string Id, string Name, string Glyph, string Summary);

public sealed record PluginCommandDescriptor(string Id, string Title);

public interface ITetherPlugin
{
    PluginMetadata Metadata { get; }
    IReadOnlyList<PluginCommandDescriptor> CommandDescriptors => [];
    void Activate();
    void Deactivate();
}

/// <summary>
/// Extensions the process loaded, and the subset a person has switched off.
/// The off-set is persisted by <paramref name="save"/>; this type does not
/// know where settings live.
/// </summary>
public sealed class PluginRegistry
{
    private readonly List<ITetherPlugin> _plugins = [];
    private readonly HashSet<string> _disabled;
    private readonly Action<IReadOnlyList<string>> _save;

    public PluginRegistry(IEnumerable<string>? disabled = null, Action<IReadOnlyList<string>>? save = null)
    {
        _disabled = new HashSet<string>(disabled ?? [], StringComparer.Ordinal);
        _save = save ?? (_ => { });
    }

    public IReadOnlyList<ITetherPlugin> Plugins => _plugins;

    public event Action? Changed;

    public void Register(ITetherPlugin plugin)
    {
        if (_plugins.Any(existing => existing.Metadata.Id == plugin.Metadata.Id))
            throw new InvalidOperationException($"Duplicate plugin {plugin.Metadata.Id}.");
        _plugins.Add(plugin);
        if (IsEnabled(plugin.Metadata.Id)) plugin.Activate();
        Changed?.Invoke();
    }

    public bool IsEnabled(string id) => !_disabled.Contains(id);

    public void SetEnabled(string id, bool enabled)
    {
        var plugin = _plugins.FirstOrDefault(item => item.Metadata.Id == id);
        if (plugin is null || enabled == IsEnabled(id)) return;
        if (enabled)
        {
            _disabled.Remove(id);
            plugin.Activate();
        }
        else
        {
            _disabled.Add(id);
            plugin.Deactivate();
        }
        _save(_disabled.Order(StringComparer.Ordinal).ToArray());
        Changed?.Invoke();
    }
}
