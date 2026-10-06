using System.Text.Json;

namespace TetherApp;

/// <summary>Reopening metadata contains no passwords or private key contents.</summary>
public sealed record ClosedTerminal(Guid Id, string Title, string Profile, string? Directory,
    string? HostAlias, string? Target, int Index, string? Inspector, Dictionary<string, string>? Attachments = null, string? Configuration = null, string? WslDistribution = null);

public sealed class SessionHistoryStore
{
    public static string Root => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Tether", "SessionHistory");
    public static string Location(Guid id) => Path.Combine(Root, id.ToString());
    private readonly string _root;
    public SessionHistoryStore(string? directory = null) => _root = directory ?? Root;
    private sealed record Manifest(int Version, ClosedTerminal[] Open, ClosedTerminal[] Closed);
    public string? Problem { get; private set; }
    private bool _canWrite = true;
    private string? _lastSaved;

    public IReadOnlyList<ClosedTerminal> Load()
    {
        try
        {
            Directory.CreateDirectory(_root);
            var file = Path.Combine(_root, "tabs.json");
            if (!File.Exists(file)) return [];
            var manifest = JsonSerializer.Deserialize<Manifest>(File.ReadAllText(file));
            if (manifest is null || manifest.Version != 1) throw new IOException("Unsupported session history.");
            _lastSaved = File.ReadAllText(file);
            return manifest.Closed.Concat(manifest.Open).TakeLast(20).ToArray();
        }
        catch (Exception ex) { Problem = ex.Message; _canWrite = false; return []; }
    }

    public void Save(IEnumerable<ClosedTerminal> open, IEnumerable<ClosedTerminal> closed)
    {
        if (!_canWrite) return;
        var temporary = Path.Combine(_root, "tabs-" + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            Directory.CreateDirectory(_root);
            var manifest = new Manifest(1, open.ToArray(), closed.TakeLast(20).ToArray());
            var json = JsonSerializer.Serialize(manifest);
            if (json == _lastSaved) return;
            File.WriteAllText(temporary, json);
            File.Move(temporary, Path.Combine(_root, "tabs.json"), true);
            _lastSaved = json;
            Problem = null;
            var retained = manifest.Open.Concat(manifest.Closed).Select(t => t.Id).ToHashSet();
            foreach (var child in Directory.EnumerateDirectories(_root))
            {
                if (!Guid.TryParse(Path.GetFileName(child), out var id) || retained.Contains(id)) continue;
                if ((File.GetAttributes(child) & FileAttributes.ReparsePoint) != 0) continue;
                var resolved = Path.GetFullPath(child);
                var boundary = Path.GetFullPath(_root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                if (resolved.StartsWith(boundary, StringComparison.OrdinalIgnoreCase)) Directory.Delete(resolved, true);
            }
        }
        catch (Exception ex) { Problem = ex.Message; }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
