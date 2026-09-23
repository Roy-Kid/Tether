// `~/.ssh/config`, read for the hosts it describes.
//
// The file is the store (Decisions/0009): a person's config carries
// `ControlMaster`, `ForwardAgent`, a comment reminding them which machine is
// which — none of which this app understands. What is parsed is an *index*,
// and nothing is written back except by the `known_hosts` trust store.
//
// Only stanzas whose first pattern is a literal name. `Host *` is settings
// for other hosts rather than a host of its own, and listing it would offer
// a person a machine called `*`.

namespace TetherApp;

public sealed record HostEntry(
    string Alias,
    string HostName,
    string? User,
    ushort? Port,
    string? IdentityFile)
{
    /// What the picker shows: the alias, which is the name a person types.</summary>
    public string Label => Alias;

    /// `user@hostname:port` — what a status line and a tooltip want.</summary>
    public string Target
    {
        get
        {
            var user = User is { Length: > 0 } ? User + "@" : "";
            var port = Port is { } p && p != 22 ? ":" + p : "";
            return $"{user}{HostName}{port}";
        }
    }
}

public static class SshConfig
{
    public static string DefaultPath
    {
        get
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return System.IO.Path.Combine(home, ".ssh", "config");
        }
    }

    /// <summary>Every host the file names, in the order it names them.</summary>
    public static IReadOnlyList<HostEntry> Load(string? path = null)
    {
        var file = path ?? DefaultPath;
        if (!File.Exists(file)) return Array.Empty<HostEntry>();

        var entries = new List<HostEntry>();
        foreach (var block in Parse(File.ReadAllLines(file)))
        {
            if (!IsLiteral(block.Patterns.FirstOrDefault())) continue;
            var alias = block.Patterns[0];
            var hostName = block.Get("HostName") ?? alias;
            entries.Add(new HostEntry(
                alias,
                hostName,
                block.Get("User"),
                block.Get("Port") is { } port && ushort.TryParse(port, out var p) ? p : null,
                block.Get("IdentityFile")));
        }
        return entries;
    }

    /// <summary>
    /// The hosts a picker should offer after <paramref name="query"/>: the
    /// alias first, then the hostname. A person typing `arr` means
    /// `Arrhenius`, not a fuzzy match on the machine's real name.
    /// </summary>
    public static IReadOnlyList<HostEntry> Filter(IEnumerable<HostEntry> hosts, string query)
    {
        if (string.IsNullOrWhiteSpace(query)) return hosts.ToList();
        var needle = query.Trim();
        return hosts
            .Where(h =>
                h.Alias.Contains(needle, StringComparison.OrdinalIgnoreCase)
                || h.HostName.Contains(needle, StringComparison.OrdinalIgnoreCase))
            .ToList();
    }

    private sealed record Block(string[] Patterns, Dictionary<string, string> Values)
    {
        public string? Get(string key) =>
            Values.TryGetValue(key.ToLowerInvariant(), out var value) ? value : null;
    }

    private static IEnumerable<Block> Parse(string[] lines)
    {
        Block? current = null;
        foreach (var raw in lines)
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;

            var parts = line.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);
            var key = parts[0];
            var value = parts.Length > 1 ? parts[1].Trim() : "";

            if (key.Equals("Host", StringComparison.OrdinalIgnoreCase))
            {
                if (current is not null) yield return current;
                current = new Block(
                    value.Split(' ', StringSplitOptions.RemoveEmptyEntries),
                    new Dictionary<string, string>());
            }
            else if (current is not null)
            {
                // First value wins, which is what ssh does when stanzas
                // overlap — so a `User` under `Host *` is the user this host
                // gets, unless its own stanza says otherwise.
                current.Values.TryAdd(key.ToLowerInvariant(), value);
            }
        }
        if (current is not null) yield return current;
    }

    private static bool IsLiteral(string? pattern) =>
        pattern is { Length: > 0 }
        && pattern != "*"
        && !pattern.Contains('*')
        && !pattern.Contains('?')
        && !pattern.StartsWith('!');
}
