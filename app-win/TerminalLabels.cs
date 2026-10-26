namespace TetherApp;

/// <summary>What one terminal can be called before twins are numbered.</summary>
public readonly record struct TerminalLabel(
    Guid Id,
    string? Pinned,
    string? Session,
    string? Command,
    string? Directory,
    string Serial);

/// <summary>
/// Chip titles for the terminals on one host, in strip order.
/// A pinned name stays as typed. Otherwise: attached session, then foreground
/// program, then directory, then <c>Terminal N</c>. Matching automatic names
/// gain a strip-order number: <c>ssh 1</c>, <c>ssh 2</c>.
/// </summary>
public static class TerminalLabels
{
    public static IReadOnlyDictionary<Guid, string> Titles(IReadOnlyList<TerminalLabel> rows)
    {
        var bases = rows.Select(Base).ToArray();
        var counts = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var item in bases.Where(item => item.Automatic))
            counts[item.Text] = counts.GetValueOrDefault(item.Text) + 1;
        var seen = new Dictionary<string, int>(StringComparer.Ordinal);
        var result = new Dictionary<Guid, string>();
        for (var index = 0; index < rows.Count; index++)
        {
            var item = bases[index];
            var twins = item.Automatic ? counts.GetValueOrDefault(item.Text) : 0;
            if (twins > 1)
            {
                var number = seen.GetValueOrDefault(item.Text) + 1;
                seen[item.Text] = number;
                result[rows[index].Id] = item.Text + " " + number;
            }
            else result[rows[index].Id] = item.Text;
        }
        return result;
    }

    /// <summary>The word Rename Terminal starts from: the pin, or the automatic name without twin number.</summary>
    public static string Seed(TerminalLabel row) => Base(row).Text;

    /// <summary>A name saved before pins existed. <c>Terminal N</c> stays automatic; anything else was typed.</summary>
    public static string? RestoredPin(string name, string? pinned)
    {
        if (Cleaned(pinned) is { } keep) return keep;
        return IsSerial(name) ? null : Cleaned(name);
    }

    public static string? DirectoryName(string? path, string? home)
    {
        if (path is null || path.Length == 0) return null;
        var unix = path.StartsWith('/') || path.StartsWith("~");
        if (!unix && path.Length >= 2 && path[1] == ':')
        {
            path = path.Replace('\\', '/');
            if (home is not null) home = home.Replace('\\', '/');
        }
        else if (!path.StartsWith('/')) return null;
        while (path.Length > 1 && path.EndsWith('/')) path = path[..^1];
        if (home is not null)
        {
            while (home.Length > 1 && home.EndsWith('/')) home = home[..^1];
            if (string.Equals(path, home, StringComparison.OrdinalIgnoreCase)) return "~";
        }
        if (path is "/" or "") return null;
        var slash = path.LastIndexOf('/');
        var baseName = slash < 0 ? path : path[(slash + 1)..];
        return Cleaned(baseName);
    }

    public static bool IsSerial(string name)
    {
        var space = name.IndexOf(' ');
        if (space <= 0 || !name.AsSpan(0, space).SequenceEqual("Terminal")) return false;
        var tail = name.AsSpan(space + 1);
        return !tail.IsEmpty && tail.ToString().All(char.IsDigit);
    }

    private static (string Text, bool Automatic) Base(TerminalLabel row)
    {
        if (Cleaned(row.Pinned) is { } pinned) return (pinned, false);
        if (Cleaned(row.Session) is { } session) return (session, true);
        if (Cleaned(row.Command) is { } command) return (command, true);
        if (Cleaned(row.Directory) is { } directory) return (directory, true);
        return (row.Serial, true);
    }

    private static string? Cleaned(string? text)
    {
        if (text is null) return null;
        var trimmed = text.Trim();
        if (trimmed.Length == 0 || trimmed.Contains('\n') || trimmed.Contains('\r')) return null;
        return trimmed;
    }
}
