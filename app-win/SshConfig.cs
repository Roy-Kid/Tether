// `~/.ssh/config`, read for the hosts it describes.
//
// The file is the store (Decisions/0009): a person's config carries
// `ControlMaster`, `ForwardAgent`, a comment reminding them which machine is
// which — none of which this app understands. What is parsed is an *index*,
// and structured edits live in SshConfigEditor, preserving other directives.
//
// A setting comes from the first stanza that matches, wildcards included,
// which is what `ssh` does. `ProxyJump` is part of that (Decisions/0019):
// the hops in front of a name, or this name would not mean what `ssh` means.
//
// Only stanzas whose first pattern is a literal name. `Host *` is settings
// for other hosts rather than a host of its own, and listing it would offer
// a person a machine called `*`.

namespace TetherApp;

public sealed record Jump(string HostName, ushort Port, string? User, string? IdentityFile,
    [property: System.Text.Json.Serialization.JsonIgnore] string? Alias = null);

public sealed record HostEntry(
    string Alias,
    string HostName,
    string? User,
    ushort? Port,
    string? IdentityFile,
    IReadOnlyList<Jump>? Jumps = null,
    string? JumpError = null,
    int? ConnectTimeoutSeconds = null)
{
    [System.Text.Json.Serialization.JsonIgnore]
    public IReadOnlyList<string> Unsupported { get; init; } = [];
    /// <summary>What the picker shows: the alias, which is the name a person types.</summary>
    public string Label => Alias;

    /// <summary>Hops in front of this host. Empty when <c>ssh</c> would dial it directly.</summary>
    public IReadOnlyList<Jump> Route => Jumps ?? Array.Empty<Jump>();

    /// <summary><c>user@hostname:port</c> — what a status line and a tooltip want.</summary>
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

    /// <summary><c>~/.ssh/id_ed25519</c> is how a path is written. Opening it needs the real path.</summary>
    public static string ExpandHome(string path)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (path == "~") return home;
        if (path.StartsWith("~/", StringComparison.Ordinal) || path.StartsWith("~\\", StringComparison.Ordinal))
            return System.IO.Path.Combine(home, path[2..]);
        return path;
    }

    /// <summary>Parses <paramref name="text"/> the way <see cref="Load"/> parses a file.</summary>
    public static IReadOnlyList<HostEntry> LoadText(string text) =>
        Document.Read(text.Replace("\r\n", "\n").Split('\n')).Entries;
    public static IReadOnlyDictionary<string, string> ResolvedDirectives(string text, string alias) =>
        Document.Read(text.Replace("\r\n", "\n").Split('\n')).Resolve(alias, preserveRaw: true);

    /// <summary>Every host the file names, in the order it names them.</summary>
    public static IReadOnlyList<HostEntry> Load(string? path = null)
    {
        var file = path ?? DefaultPath;
        if (!File.Exists(file)) return Array.Empty<HostEntry>();
        return Document.Read(File.ReadAllLines(file)).Entries;
    }

    /// <summary>
    /// The hosts a picker should offer after <paramref name="query"/>: the
    /// alias first, then the hostname. A person typing <c>arr</c> means
    /// <c>Arrhenius</c>, not a fuzzy match on the machine's real name.
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

    /// <summary>The file, indexed the way <c>SSHConfig.swift</c> indexes it.</summary>
    private sealed class Document
    {
        private readonly string[] _lines;
        private readonly List<Block> _blocks;

        private Document(string[] lines, List<Block> blocks)
        {
            _lines = lines;
            _blocks = blocks;
        }

        public static Document Read(string[] lines)
        {
            var blocks = new List<Block> { new(["*"], -1, lines.Length) };
            for (var index = 0; index < lines.Length; index++)
            {
                if (Directive(lines[index]) is not { } directive) continue;
                if (directive.Keyword != "host" && directive.Keyword != "match") continue;

                if (blocks.Count > 0) blocks[^1].End = index;
                if (directive.Keyword == "host")
                {
                    blocks.Add(new Block(Tokens(directive.Value).ToArray(), index, lines.Length));
                }
            }
            return new Document(lines, blocks);
        }

        public IReadOnlyList<HostEntry> Entries
        {
            get
            {
                var entries = new List<HostEntry>();
                var names = new HashSet<string>(StringComparer.Ordinal);
                foreach (var block in _blocks)
                {
                    if (block.Patterns.Length == 0 || !IsLiteral(block.Patterns[0])) continue;
                    var alias = block.Patterns[0];
                    if (!names.Add(alias)) continue;
                    var settings = Resolve(alias);
                    var (jumps, error) = Jumps(alias);
                    int? timeout = null;
                    if (settings.TryGetValue("connecttimeout", out var timeoutText)
                        && int.TryParse(timeoutText, out var seconds)
                        && seconds > 0)
                        timeout = seconds;
                    entries.Add(new HostEntry(
                        alias,
                        settings.GetValueOrDefault("hostname") ?? alias,
                        settings.GetValueOrDefault("user"),
                        settings.TryGetValue("port", out var port) && ushort.TryParse(port, out var parsed) ? parsed : null,
                        settings.GetValueOrDefault("identityfile"),
                        jumps,
                        error,
                        timeout) { Unsupported = settings.Where(p => p.Key is "proxycommand" or "remotecommand" or "hostkeyalias" or "canonicalizehostname" or "sessiontype" or "include")
                            .Where(p => p.Value is not ("none" or "no")).Select(p => p.Key).ToArray() });
                }
                return entries;
            }
        }

        public Dictionary<string, string> Resolve(string alias, bool preserveRaw = false)
        {
            var settings = new Dictionary<string, string>();
            foreach (var block in _blocks)
            {
                if (!Matches(block.Patterns, alias)) continue;
                for (var index = block.Start + 1; index < block.End; index++)
                {
                    if (Directive(_lines[index]) is not { } directive || directive.Keyword == "host") continue;
                    if (settings.ContainsKey(directive.Keyword)) continue;
                    if (preserveRaw || directive.Keyword == "proxyjump")
                    {
                        var value = directive.Value.Trim();
                        if (value.Length > 0) settings[directive.Keyword] = value;
                        continue;
                    }
                    var first = Tokens(directive.Value);
                    if (first.Count > 0) settings[directive.Keyword] = first[0];
                }
            }
            return settings;
        }

        private (IReadOnlyList<Jump> Hops, string? Error) Jumps(string alias)
        {
            var chain = new List<Jump>();
            var visiting = new List<string>();
            try
            {
                Expand(alias, visiting, chain);
                return (chain, null);
            }
            catch (CycleException cycle)
            {
                return (Array.Empty<Jump>(), $"ProxyJump for {alias} cycles through {cycle.Name}.");
            }
            catch (JumpParseException error)
            {
                return (Array.Empty<Jump>(), error.Message);
            }
        }

        private void Expand(string alias, List<string> visiting, List<Jump> chain)
        {
            if (visiting.Contains(alias))
                throw new CycleException(alias);
            if (chain.Count > 16)
                throw new JumpParseException($"ProxyJump for {alias} is too long.");
            visiting.Add(alias);
            try
            {
                var settings = Resolve(alias);
                if (!settings.TryGetValue("proxyjump", out var raw)) return;
                if (raw.Equals("none", StringComparison.OrdinalIgnoreCase)) return;

                foreach (var piece in raw.Split(','))
                {
                    var token = piece.Trim();
                    if (token.Length == 0) continue;
                    var spec = JumpSpec.Parse(token, alias);
                    Expand(spec.Host, visiting, chain);
                    var hop = Resolve(spec.Host);
                    var port = spec.Port
                        ?? (hop.TryGetValue("port", out var text) && ushort.TryParse(text, out var parsed) ? parsed : (ushort)22);
                    chain.Add(new Jump(
                        hop.GetValueOrDefault("hostname") ?? spec.Host,
                        port,
                        spec.User ?? hop.GetValueOrDefault("user"),
                        hop.GetValueOrDefault("identityfile"), spec.Host));
                    if (chain.Count > 16)
                        throw new JumpParseException($"ProxyJump for {alias} is too long.");
                }
            }
            finally
            {
                visiting.RemoveAt(visiting.Count - 1);
            }
        }

        private sealed class Block(string[] patterns, int start, int end)
        {
            public string[] Patterns { get; } = patterns;
            public int Start { get; } = start;
            public int End { get; set; } = end;
        }
    }

    private sealed class JumpParseException(string message) : Exception(message);

    private sealed class CycleException(string name) : Exception(name)
    {
        public string Name { get; } = name;
    }

    private readonly struct JumpSpec(string? user, string host, ushort? port)
    {
        public string? User { get; } = user;
        public string Host { get; } = host;
        public ushort? Port { get; } = port;

        public static JumpSpec Parse(string token, string alias)
        {
            var rest = token;
            string? user = null;
            var at = rest.IndexOf('@');
            if (at >= 0)
            {
                user = rest[..at];
                if (user.Length == 0)
                    throw new JumpParseException($"ProxyJump for {alias} has an unreadable hop ({token}).");
                rest = rest[(at + 1)..];
            }

            if (rest.StartsWith('['))
            {
                var end = rest.IndexOf(']');
                if (end < 0)
                    throw new JumpParseException($"ProxyJump for {alias} has an unreadable hop ({token}).");
                var host = rest[1..end];
                var after = rest[(end + 1)..];
                ushort? port = null;
                if (after.Length > 0)
                {
                    if (!after.StartsWith(':') || !ushort.TryParse(after[1..], out var parsed))
                        throw new JumpParseException($"ProxyJump for {alias} has an unreadable hop ({token}).");
                    port = parsed;
                }
                return new JumpSpec(user, host, port);
            }

            var colon = rest.LastIndexOf(':');
            if (colon > 0 && colon < rest.Length - 1 && ushort.TryParse(rest[(colon + 1)..], out var numeric))
                return new JumpSpec(user, rest[..colon], numeric);
            if (rest.Length == 0)
                throw new JumpParseException($"ProxyJump for {alias} has an unreadable hop ({token}).");
            return new JumpSpec(user, rest, null);
        }
    }

    private readonly struct Line(string keyword, string value)
    {
        public string Keyword { get; } = keyword;
        public string Value { get; } = value;
    }

    private static Line? Directive(string line)
    {
        var trimmed = line.Trim();
        if (trimmed.Length == 0 || trimmed.StartsWith('#')) return null;

        var split = -1;
        for (var i = 0; i < trimmed.Length; i++)
        {
            if (trimmed[i] is ' ' or '\t' or '=') { split = i; break; }
        }
        if (split < 0) return new Line(trimmed.ToLowerInvariant(), "");
        var keyword = trimmed[..split].ToLowerInvariant();
        var value = trimmed[(split + 1)..].Trim().TrimStart('=').Trim();
        return new Line(keyword, value);
    }

    private static List<string> Tokens(string value)
    {
        var tokens = new List<string>();
        var current = new System.Text.StringBuilder();
        var quoting = false;
        foreach (var character in value)
        {
            if (character == '"') quoting = !quoting;
            else if (!quoting && character is ' ' or '\t')
            {
                if (current.Length > 0) { tokens.Add(current.ToString()); current.Clear(); }
            }
            else current.Append(character);
        }
        if (current.Length > 0) tokens.Add(current.ToString());
        return tokens;
    }

    private static bool IsLiteral(string pattern) =>
        pattern.Length > 0 && !pattern.Contains('*') && !pattern.Contains('?') && !pattern.StartsWith('!');

    private static bool Matches(string[] patterns, string alias)
    {
        var matched = false;
        foreach (var pattern in patterns)
        {
            if (pattern.StartsWith('!'))
            {
                if (Glob(pattern[1..], alias)) return false;
            }
            else if (Glob(pattern, alias)) matched = true;
        }
        return matched;
    }

    private static bool Glob(string pattern, string text)
    {
        var memo = new bool?[pattern.Length + 1, text.Length + 1];
        return Match(0, 0);

        bool Match(int p, int t)
        {
            if (memo[p, t] is { } known) return known;
            bool answer;
            if (p == pattern.Length) answer = t == text.Length;
            else if (pattern[p] == '*') answer = Match(p + 1, t) || (t < text.Length && Match(p, t + 1));
            else if (t < text.Length && (pattern[p] == '?' || pattern[p] == text[t])) answer = Match(p + 1, t + 1);
            else answer = false;
            memo[p, t] = answer;
            return answer;
        }
    }
}
