// Where a path printed in a terminal might actually be, and how to type one
// back at a prompt. The same rules as the Mac file plugin: a relative path
// is tried where the program was, then where the browser is, then home,
// and only a path the far side confirms is opened.

namespace TetherApp.Files;

public enum QuoteStyle { Posix, PowerShell, Cmd }

public static class FilesPaths
{
    /// <summary>A <c>file:</c> URI's path, or null when it is not one.</summary>
    public static string? FileUri(string uri)
    {
        if (!uri.StartsWith("file:", StringComparison.OrdinalIgnoreCase)) return null;
        if (!Uri.TryCreate(uri, UriKind.Absolute, out var parsed) || parsed.Scheme != "file") return null;
        var path = Uri.UnescapeDataString(parsed.AbsolutePath);
        return path.Length == 0 ? null : path;
    }

    /// <summary>
    /// Places a printed path might name, most likely first. An absolute path
    /// is only itself. <c>~/x</c> is home. Anything else is relative to each
    /// base, in order, without repeating a base.
    /// </summary>
    public static IReadOnlyList<string> Candidates(string printed, string? working, string? browser, string? home)
    {
        if (printed.StartsWith('/')) return [printed];
        if (printed == "~") return home is { Length: > 0 } ? [home] : [];
        if (printed.StartsWith("~/"))
            return home is { Length: > 0 } ? [Join(home, printed[2..])] : [];

        var relative = printed.StartsWith("./") ? printed[2..] : printed;
        var bases = new List<string>();
        foreach (var basis in new[] { working, browser, home })
        {
            if (basis is { Length: > 0 } && !bases.Contains(basis)) bases.Add(basis);
        }
        return bases.Select(basis => Join(basis, relative)).ToArray();
    }

    public static string Join(string directory, string name)
    {
        var child = name.Replace('\\', '/').TrimStart('/');
        if (directory.Contains('\\') && !directory.StartsWith("//", StringComparison.Ordinal))
            return System.IO.Path.Combine(directory, child.Replace('/', '\\'));
        return directory.TrimEnd('/') + "/" + child;
    }

    /// <summary>How this shell wants a path written so it stays one word.</summary>
    public static QuoteStyle StyleFor(bool remote, bool wsl, string localProfile) =>
        remote || wsl ? QuoteStyle.Posix
        : System.IO.Path.GetFileNameWithoutExtension(localProfile)
            .Equals("cmd", StringComparison.OrdinalIgnoreCase) ? QuoteStyle.Cmd
        : QuoteStyle.PowerShell;

    public static string Quote(string path, QuoteStyle style) => style switch
    {
        QuoteStyle.Cmd => "\"" + path + "\"",
        QuoteStyle.PowerShell => "'" + path.Replace("'", "''", StringComparison.Ordinal) + "'",
        _ => "'" + path.Replace("'", "'\\''", StringComparison.Ordinal) + "'",
    };

    public static bool CmdUnsafe(string path) => path.IndexOfAny(['%', '!', '"']) >= 0;
}
