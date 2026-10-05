using System.Text.RegularExpressions;

namespace TetherApp;

public static class ShellTTY
{
    public static bool IsDevice(string value) => Regex.IsMatch(value, @"^/dev/(pts/[0-9]+|ttys[0-9]+)$", RegexOptions.CultureInvariant);
    public static async Task<string?> FindAsync(SessionModel model, CancellationToken token)
    {
        if (model.TerminalName is { } known) return known;
        if (!model.IsRemote) return null;
        var text = await model.ExecuteAsync("printf '%s\\n' \"TETHER-TTY $$\"; ps -ax -o pid= -o ppid= -o tty=; printf '%s\\n' TETHER-TTY-END", token);
        var candidates = Candidates(text);
        if (candidates.Count <= 1) return candidates.FirstOrDefault();
        var names = string.Join(" ", candidates.Select(t => "'" + t + "'"));
        var sizes = await model.ExecuteAsync("for t in " + names + "; do size=$(stty -F \"$t\" size 2>/dev/null || stty -f \"$t\" size 2>/dev/null) || continue; printf '%s %s\\n' \"$t\" \"$size\"; done", token);
        var matches = sizes.Split('\n').Select(line => line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
            .Where(p => p.Length == 3 && candidates.Contains(p[0]) && ushort.TryParse(p[1], out var rows) && rows == model.Rows &&
                ushort.TryParse(p[2], out var columns) && columns == model.Columns).Select(p => p[0]).Distinct().ToArray();
        return matches.Length == 1 ? matches[0] : null;
    }

    public static IReadOnlyList<string> Candidates(string text) => ProcessTable.TtyCandidates(text);

}
