// `~/.ssh/known_hosts`, and nothing else.
//
// The one host-trust store (the user's rule, and the same file every other
// OpenSSH client writes). Asking again for a host someone already vouched
// for trains them to accept without reading, which is the failure mode the
// prompt exists to prevent. Remembering is what makes the *second* prompt
// mean something.
//
// Fingerprints and keys only. A key is public — it is what an administrator
// publishes — so this file discloses nothing and holds no credential of any
// kind (spec §18).
//
// Format (OpenSSH `sshd(8)`):
//
//     hostname[,hostname2…] keytype base64blob [comment]
//     [host]:port          keytype base64blob
//     |1|salt|hash         keytype base64blob        ← hashed host
//     @revoked             keytype base64blob
//     @cert-authority      keytype base64blob

using System.Security.Cryptography;
using System.Text;

namespace Tether;

/// <summary>What a person is being asked, when they are asked at all.</summary>
public abstract record TrustQuestion
{
    /// <summary>Never seen this endpoint before.</summary>
    public sealed record Unknown() : TrustQuestion;

    /// <summary>
    /// Seen it, and the key is not the one recorded. The dangerous case, and
    /// the whole reason a record is kept: a key that changes under a host is
    /// either an administrator rotating it or someone standing in the middle,
    /// and only the person can tell which.
    /// </summary>
    public sealed record Changed(string Algorithm, string Fingerprint) : TrustQuestion;

    /// <summary>
    /// The key is on the <c>@revoked</c> list. Not a question: OpenSSH
    /// refuses the connection outright, and so do we. A person cannot
    /// re-trust a revoked key by pressing a button — that is what revocation
    /// means (spec §18).
    /// </summary>
    public sealed record Revoked(string Algorithm, string Fingerprint) : TrustQuestion;
}

/// <summary>The keys a person has accepted, across launches, in <c>known_hosts</c>.</summary>
public sealed class KnownHosts
{
    private readonly string _path;
    private readonly object _gate = new();

    /// <summary>Defaults to <c>~/.ssh/known_hosts</c>.</summary>
    public KnownHosts(string? path = null)
    {
        _path = path ?? DefaultPath();
    }

    public string Path => _path;

    public static string DefaultPath()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return System.IO.Path.Combine(home, ".ssh", "known_hosts");
    }

    /// <summary>
    /// <c>null</c> when the key is already trusted for this endpoint and
    /// nobody needs to be asked.
    /// </summary>
    public TrustQuestion? Question(HostIdentity host)
    {
        lock (_gate)
        {
            var entries = Load();
            var matches = entries.Where(e => e.Matches(host.Host, host.Port)).ToList();

            // A revoked key is not a question. It is refused before anything
            // else is considered — including a matching key recorded without
            // the marker, which is exactly what a revoke is meant to override.
            if (matches.Any(e => e.IsRevoked(host)))
            {
                return new TrustQuestion.Revoked(host.Algorithm, host.Fingerprint);
            }

            var sameHost = matches.Where(e => e.Marker.Length == 0).ToList();
            if (sameHost.Count == 0) return new TrustQuestion.Unknown();

            if (sameHost.Any(e => e.MatchesKey(host))) return null;
            return new TrustQuestion.Changed(host.Algorithm, host.Fingerprint);
        }
    }

    /// <summary>Records an acceptance, replacing any earlier key for that endpoint.</summary>
    public void Remember(HostIdentity host)
    {
        lock (_gate)
        {
            var entries = Load();
            var pattern = HostPattern(host.Host, host.Port);
            var keyLine = KeyLine(host);

            // Drop earlier keys for the same endpoint so a rotated key
            // replaces rather than accumulates.
            entries.RemoveAll(e =>
                e.Marker.Length == 0
                && e.Patterns.Any(p => p == pattern)
                && e.KeyType == host.Algorithm);

            entries.Add(new Entry("", new[] { pattern }, host.Algorithm, keyLine, []));
            Save(entries);
        }
    }

    public void Forget(string host, ushort port)
    {
        lock (_gate)
        {
            var entries = Load();
            var pattern = HostPattern(host, port);
            entries.RemoveAll(e => e.Patterns.Any(p => p == pattern));
            Save(entries);
        }
    }

    /// <summary>
    /// The host pattern OpenSSH writes: <c>host</c>, or <c>[host]:port</c>
    /// when the port is not the default.
    /// </summary>
    public static string HostPattern(string host, ushort port) =>
        port == 22 ? host : $"[{host}]:{port}";

    /// <summary>The key portion of a <c>known_hosts</c> line: <c>ssh-ed25519 AAAA…</c>.</summary>
    public static string KeyLine(HostIdentity host)
    {
        var text = Encoding.UTF8.GetString(host.Encoded).Trim();
        return text.Length > 0 ? text : $"{host.Algorithm}";
    }

    // ---- parsing ----

    private sealed record Entry(
        string Marker,
        string[] Patterns,
        string KeyType,
        string KeyBlob,
        string[] Rest)
    {
        public string Line
        {
            get
            {
                var parts = new List<string>();
                if (Marker.Length > 0) parts.Add(Marker);
                parts.Add(string.Join(",", Patterns));
                parts.Add(KeyType);
                parts.Add(KeyBlob);
                parts.AddRange(Rest);
                return string.Join(' ', parts);
            }
        }

        public bool Matches(string host, ushort port)
        {
            var wanted = HostPattern(host, port);
            return Patterns.Any(p => PatternMatches(p, host, port, wanted));
        }

        public bool MatchesKey(HostIdentity host) =>
            KeyType == host.Algorithm && KeyBlob == BlobOf(KeyLine(host));

        public bool IsRevoked(HostIdentity host) =>
            Marker == "@revoked" && MatchesKey(host);
    }

    private static string BlobOf(string keyLine)
    {
        var parts = keyLine.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length >= 2 ? parts[1] : "";
    }

    private static bool PatternMatches(string pattern, string host, ushort port, string wanted)
    {
        if (pattern == wanted || pattern == host) return true;
        // `[host]:port` matches only that port.
        if (pattern.StartsWith('[') && pattern == HostPattern(host, port)) return true;
        // Hashed host: |1|salt|hash = base64(HMAC-SHA1(salt, hostname)).
        if (pattern.StartsWith("|1|")) return HashedHostMatches(pattern, host);
        // Wildcards are rare in known_hosts but legal.
        if (pattern.Contains('*') || pattern.Contains('?'))
            return GlobMatches(pattern, host) || GlobMatches(pattern, wanted);
        return false;
    }

    private static bool HashedHostMatches(string pattern, string host)
    {
        // |1|<salt-b64>|<hash-b64>
        var parts = pattern.Split('|');
        if (parts.Length != 4) return false;
        byte[] salt, expected;
        try
        {
            salt = Convert.FromBase64String(parts[2]);
            expected = Convert.FromBase64String(parts[3]);
        }
        catch (FormatException)
        {
            return false;
        }

        // OpenSSH hashes the hostname only, never the port.
        using var hmac = new HMACSHA1(salt);
        var actual = hmac.ComputeHash(Encoding.UTF8.GetBytes(host));
        return actual.AsSpan().SequenceEqual(expected);
    }

    private static bool GlobMatches(string pattern, string value)
    {
        // Minimal `*`/`?` match, enough for the rare wildcard line.
        var regex = "^" + System.Text.RegularExpressions.Regex.Escape(pattern)
            .Replace("\\*", ".*").Replace("\\?", ".") + "$";
        return System.Text.RegularExpressions.Regex.IsMatch(value, regex);
    }

    private List<Entry> Load()
    {
        var entries = new List<Entry>();
        if (!File.Exists(_path)) return entries;

        foreach (var raw in File.ReadLines(_path))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;

            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 3) continue;

            var index = 0;
            var marker = "";
            if (parts[0].StartsWith('@'))
            {
                marker = parts[0];
                index = 1;
            }
            if (parts.Length - index < 3) continue;

            var patterns = parts[index].Split(',');
            var keyType = parts[index + 1];
            var keyBlob = parts[index + 2];
            var rest = parts.Skip(index + 3).ToArray();
            entries.Add(new Entry(marker, patterns, keyType, keyBlob, rest));
        }
        return entries;
    }

    private void Save(List<Entry> entries)
    {
        var directory = System.IO.Path.GetDirectoryName(_path);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);

        // OpenSSH appends with 0600. We rewrite the file we own the lines of
        // and leave every line we did not parse untouched — the same rule
        // `Decision/0009` sets for `~/.ssh/config`.
        var lines = new List<string>();
        if (File.Exists(_path))
        {
            foreach (var raw in File.ReadLines(_path))
            {
                var trimmed = raw.Trim();
                if (trimmed.Length == 0 || trimmed.StartsWith('#') || Parseable(trimmed))
                {
                    // Keep comments and blanks; parseable lines are rewritten
                    // from the entry list below so a replaced key does not
                    // linger. Unparseable lines are kept verbatim.
                    if (!Parseable(trimmed)) lines.Add(raw);
                    continue;
                }
                lines.Add(raw);
            }
        }
        lines.AddRange(entries.Select(e => e.Line));
        File.WriteAllLines(_path, lines);
    }

    private static bool Parseable(string line)
    {
        var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var index = parts.Length > 0 && parts[0].StartsWith('@') ? 1 : 0;
        return parts.Length - index >= 3;
    }
}
