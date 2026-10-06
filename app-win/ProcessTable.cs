using System.Text.RegularExpressions;

namespace TetherApp;

public static class ProcessTable
{
    public static bool IsDevice(string value) => Regex.IsMatch(value, @"^/dev/(pts/[0-9]+|ttys[0-9]+)$", RegexOptions.CultureInvariant);
    public static IReadOnlyList<string> TtyCandidates(string text)
    {
        var lines = text.Split('\n', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        var start = Array.FindIndex(lines, l => l.StartsWith("TETHER-TTY ", StringComparison.Ordinal));
        var end = Array.IndexOf(lines, "TETHER-TTY-END");
        if (start < 0 || end <= start || !int.TryParse(lines[start][11..], out var self)) return [];
        var parent = new Dictionary<int, int>();
        var children = new Dictionary<int, List<int>>();
        var tty = new Dictionary<int, string>();
        foreach (var line in lines[(start + 1)..end])
        {
            var parts = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length != 3 || !int.TryParse(parts[0], out var pid) || !int.TryParse(parts[1], out var ppid)) return [];
            parent[pid] = ppid;
            if (!children.TryGetValue(ppid, out var owned)) children[ppid] = owned = [];
            owned.Add(pid);
            var device = parts[2].StartsWith('/') ? parts[2] : "/dev/" + parts[2];
            if (IsDevice(device)) tty[pid] = device;
        }
        HashSet<int> Descendants(int root)
        {
            var visited = new HashSet<int>(); var stack = new Stack<int>(); stack.Push(root);
            while (stack.TryPop(out var pid))
            {
                if (!visited.Add(pid)) continue;
                if (children.TryGetValue(pid, out var owned)) foreach (var child in owned) stack.Push(child);
            }
            return visited;
        }
        if (!parent.ContainsKey(self)) return [];
        var subtree = Descendants(self);
        var ancestors = new HashSet<int>();
        var current = self;
        for (var i = 0; i < 32 && parent.TryGetValue(current, out var ancestor) && ancestors.Add(ancestor); i++)
        {
            var found = Descendants(ancestor).Where(pid => !subtree.Contains(pid) && tty.ContainsKey(pid)).Select(pid => tty[pid]).Distinct().Order().ToArray();
            if (found.Length > 0) return found;
            current = ancestor;
        }
        return [];
    }
    public static string? CloseNote(string text, string? terminal)
    {
        if (terminal is null) return "Unable to check running processes.";
        var lines = text.Split('\n', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        var start = Array.IndexOf(lines, "TETHER-PROCESSES");
        var end = Array.IndexOf(lines, "TETHER-PROCESSES-END");
        if (start < 0 || end <= start) return "Unable to check running processes.";
        var rows = new List<(int Pid, int Parent, string Tty, string State, string Name)>();
        foreach (var line in lines[(start + 1)..end])
        {
            var parts = line.Split((char[]?)null, 5, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length != 5 || !int.TryParse(parts[0], out var pid) || !int.TryParse(parts[1], out var parent))
                return "Unable to check running processes.";
            rows.Add((pid, parent, parts[2].Replace("/dev/", ""), parts[3], Path.GetFileName(parts[4])));
        }
        var tty = terminal.Replace("/dev/", "");
        var owned = rows.Where(r => r.Tty == tty).Select(r => r.Pid).ToHashSet();
        var roots = rows.Where(r => owned.Contains(r.Pid) && !owned.Contains(r.Parent)).ToArray();
        if (roots.Length != 1) return "Unable to check running processes.";
        bool changed;
        do { changed = false; foreach (var row in rows) if (owned.Contains(row.Parent)) changed |= owned.Add(row.Pid); } while (changed);
        var shells = new[] { "sh", "bash", "zsh", "fish", "dash", "ash", "ksh", "nu", "tcsh", "csh" };
        var names = rows.Where(r => owned.Contains(r.Pid) && !r.State.StartsWith('Z') && !r.State.StartsWith('X') &&
            !(r.Pid == roots[0].Pid && shells.Contains(r.Name.TrimStart('-')) && (r.State.StartsWith('S') || r.State.StartsWith('I'))))
            .Select(r => r.Name).Distinct().Order().ToArray();
        return names.Length == 0 ? null : "Running: " + string.Join(", ", names);
    }

}
