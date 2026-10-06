using System.Text;
using System.Text.RegularExpressions;

namespace TetherApp;

public sealed record HostDraft(string Alias, string HostName, string User, ushort Port = 22,
    string? IdentityFile = null, string? ProxyJump = null, int Timeout = 15);

/// <summary>Edits one literal host without rewriting unrelated OpenSSH directives.</summary>
public static class SshConfigEditor
{
    private static readonly HashSet<string> Managed = new(StringComparer.OrdinalIgnoreCase)
        { "hostname", "user", "port", "identityfile", "proxyjump", "connecttimeout" };
    public static void Validate(HostDraft host)
    {
        static bool Token(string s) => s.Length > 0 && !s.StartsWith('-') && !s.Any(c => char.IsWhiteSpace(c) || char.IsControl(c) || "\"#=".Contains(c));
        if (!Token(host.Alias) || host.Alias.IndexOfAny(['*', '?', '!']) >= 0 || !Token(host.HostName) || !Token(host.User) || host.Port == 0 || host.Timeout <= 0)
            throw new IOException("Enter a literal host name, address, username, port (1–65535), and positive timeout.");
        foreach (var value in new[] { host.IdentityFile, host.ProxyJump })
            if (value?.Any(c => char.IsControl(c) || c == '"') == true) throw new IOException("Key paths and jump routes cannot contain control characters or quotes.");
    }

    public static string Update(string text, string? originalAlias, HostDraft? draft, IEnumerable<string>? additionalDirectives = null)
    {
        if (draft is not null) Validate(draft);
        if (draft is not null && draft.Alias != originalAlias && SshConfig.LoadText(text).Any(h => h.Alias == draft.Alias))
            throw new IOException("A host with this label already exists.");
        var lines = text.Replace("\r\n", "\n").Split('\n').ToList();
        var kept = new List<string>();
        for (var i = 0; i < lines.Count;)
        {
            var match = Regex.Match(lines[i], @"^\s*Host(?:\s+|\s*=\s*)([^#]+)", RegexOptions.IgnoreCase);
            if (!match.Success) { kept.Add(lines[i++]); continue; }
            var end = i + 1;
            while (end < lines.Count && !Regex.IsMatch(lines[end], @"^\s*(Host|Match)(?:\s|=)", RegexOptions.IgnoreCase)) end++;
            var patterns = match.Groups[1].Value.Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (originalAlias is null || !patterns.Contains(originalAlias, StringComparer.Ordinal))
            { kept.AddRange(lines.GetRange(i, end - i)); i = end; continue; }
            // A shared stanza continues to govern its other aliases. Unknown options
            // are copied into the edited host rather than silently discarded.
            var remaining = patterns.Where(p => p != originalAlias).ToArray();
            if (remaining.Length > 0)
            {
                var comment = lines[i].IndexOf('#');
                kept.Add("Host " + string.Join(" ", remaining) + (comment >= 0 ? " " + lines[i][comment..] : ""));
                kept.AddRange(lines.GetRange(i + 1, end - i - 1));
            }
            var inherited = new List<string>();
            foreach (var line in lines.GetRange(i + 1, end - i - 1))
            {
                var directive = Regex.Match(line, @"^\s*([^\s=#]+)");
                if (!directive.Success || !Managed.Contains(directive.Groups[1].Value)) inherited.Add(line);
            }
            // Leave unknown directives at their original precedence relative to
            // wildcard stanzas; only the edited fields are promoted to the front.
            if (draft is not null && inherited.Any(line => !string.IsNullOrWhiteSpace(line)))
            {
                var comment = lines[i].IndexOf('#');
                kept.Add("Host " + draft.Alias + (comment >= 0 ? " " + lines[i][comment..] : ""));
                kept.AddRange(inherited);
            }
            i = end;
        }
        if (draft is null) return string.Join("\n", kept);
        var block = new StringBuilder().AppendLine("Host " + draft.Alias)
            .AppendLine("    HostName " + draft.HostName).AppendLine("    User " + draft.User)
            .AppendLine("    Port " + draft.Port).AppendLine("    ConnectTimeout " + draft.Timeout)
            .AppendLine("    ProxyJump " + (string.IsNullOrWhiteSpace(draft.ProxyJump) ? "none" : draft.ProxyJump.Trim()));
        if (!string.IsNullOrWhiteSpace(draft.IdentityFile)) block.AppendLine("    IdentityFile \"" + draft.IdentityFile + "\"");
        foreach (var line in additionalDirectives ?? []) block.AppendLine(line);
        block.AppendLine().Append(string.Join("\n", kept));
        var result = block.ToString();
        var parsed = SshConfig.LoadText(result).First(h => h.Alias == draft.Alias);
        if (parsed.JumpError is { } error) throw new IOException(error);
        return result;
    }

    public static string Import(string destination, string source, IEnumerable<string> aliases, string sourceDirectory)
    {
        var updated = destination;
        var hosts = SshConfig.LoadText(source);
        foreach (var alias in aliases.Distinct())
        {
            var host = hosts.Single(h => h.Alias == alias);
            if (host.JumpError is not null) throw new IOException(host.JumpError);
            var options = SshConfig.ResolvedDirectives(source, alias);
            if (options.ContainsKey("include")) throw new IOException("Import the included file directly for " + alias + ".");
            var key = host.IdentityFile;
            if (!string.IsNullOrWhiteSpace(key) && key != "none" && !key.StartsWith('~') && !Path.IsPathRooted(key)) key = Path.GetFullPath(Path.Combine(sourceDirectory, key));
            var draft = new HostDraft(alias, host.HostName, host.User ?? Environment.UserName, host.Port ?? 22, key,
                options.GetValueOrDefault("proxyjump"), host.ConnectTimeoutSeconds ?? 15);
            var extras = options.Where(p => !Managed.Contains(p.Key)).Select(p => "    " + p.Key + " " + p.Value);
            updated = Update(updated, null, draft, extras);
        }
        if (SshConfig.LoadText(updated).FirstOrDefault(h => h.JumpError is not null) is { } invalid) throw new IOException(invalid.JumpError);
        return updated;
    }

    public static void Save(string expected, string updated, string? path = null, Action? beforeReplace = null)
    {
        path ??= SshConfig.DefaultPath;
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        using var fileLock = new FileStream(path + ".tether-lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        var current = File.Exists(path) ? File.ReadAllText(path) : "";
        if (current != expected) throw new IOException("SSH config changed while editing. Reopen the host and apply your changes.");
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllText(temporary, updated, new UTF8Encoding(false)); beforeReplace?.Invoke(); File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
