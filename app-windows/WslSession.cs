using Tether;

namespace TetherApp;

/// <summary>A terminal and all its background operations stay on one WSL distribution.</summary>
public sealed class WslSession : IAsyncDisposable
{
    public string Distribution { get; }
    private readonly string _marker = "/tmp/tether-tty-" + Guid.NewGuid().ToString("N");
    private readonly CancellationTokenSource _lifetime = new();
    private WslSession(string distribution) => Distribution = distribution;
    public static string Program => Path.Combine(Environment.SystemDirectory, "wsl.exe");
    public static async Task<IReadOnlyList<string>> DistributionsAsync() =>
        (await BoundedProcess.RunAsync(Program, ["--list", "--quiet"], limit: 32768, outputEncoding: System.Text.Encoding.Unicode))
        .Split(['\r', '\n'], StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).Where(d => !d.Any(char.IsControl)).ToArray();
    public static async Task<WslSession> CreateAsync(CancellationToken token, string? selectedDistribution = null)
    {
        var arguments = new List<string>();
        if (selectedDistribution is not null) { arguments.Add("--distribution"); arguments.Add(selectedDistribution); }
        arguments.AddRange(["--exec", "sh", "-c", "printf '%s' \"$WSL_DISTRO_NAME\""]);
        var distribution = (await BoundedProcess.RunAsync(Program, arguments, token: token, limit: 4096)).Trim();
        if (string.IsNullOrWhiteSpace(distribution) || distribution.Any(char.IsControl)) throw new IOException("No default WSL distribution is available.");
        return new(distribution);
    }
    public IReadOnlyList<string> ShellArguments(string? directory) =>
        ["--distribution", Distribution, "--cd", string.IsNullOrWhiteSpace(directory) ? "~" : directory,
         "--exec", "sh", "-c", "umask 077; set -C; printf '%s\n%s\n' \"$(tty)\" \"$$\" > " + Quote(_marker) + " || exit 1; exec \"${SHELL:-/bin/sh}\" -l"];
    public async Task<string> ExecuteAsync(string script, CancellationToken token = default)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, _lifetime.Token);
        return await BoundedProcess.RunAsync(Program, ["--distribution", Distribution, "--exec", "sh", "-s"], script.Replace("\r\n", "\n") + "\n", linked.Token);
    }
    public async Task<string?> TerminalNameAsync(CancellationToken token)
    {
        // A unique file written from inside this terminal avoids guessing by size
        // or selecting another terminal's client when several WSL tabs are open.
        var name = (await ExecuteAsync("test -f " + Quote(_marker) + " && test ! -L " + Quote(_marker) + " && head -n 1 " + Quote(_marker), token)).Trim();
        return ProcessTable.IsDevice(name) ? name : null;
    }
    public async Task<string?> DirectoryAsync(CancellationToken token)
    {
        var pidText = (await ExecuteAsync("test ! -L " + Quote(_marker) + " && sed -n '2p' " + Quote(_marker), token)).Trim();
        if (!uint.TryParse(pidText, out var pid) || pid == 0) return null;
        var path = (await ExecuteAsync("readlink /proc/" + pid + "/cwd", token)).TrimEnd('\r', '\n');
        return path.StartsWith('/') && !path.Any(char.IsControl) ? path : null;
    }
    public async Task<IReadOnlyList<TmuxSessionInfo>> SessionsAsync(CancellationToken token)
    {
        var text = await ExecuteAsync("command -v tmux >/dev/null || { printf '%s\\n' 'Install tmux in this WSL distribution.' >&2; exit 127; }; tmux list-sessions -F '#{session_id}|#{session_attached}|#{session_name}' 2>/dev/null || { tmux has-session 2>/dev/null && exit 1; exit 0; }", token);
        var sessions = ParseSessions(text);
        var result = new List<TmuxSessionInfo>();
        foreach (var session in sessions)
        {
            var windows = await ExecuteAsync("tmux list-windows -t " + SessionId(session.Id) + " -F '#{window_id}|#{window_index}|#{window_active}|#{window_panes}|#{window_name}'", token);
            result.Add(session with { Windows = ParseWindows(windows) });
        }
        return result;
    }
    public async Task<TmuxSessionInfo> CreateAsync(string name, string? directory, CancellationToken token)
    {
        var command = "tmux new-session -d -P -F '#{session_id}|#{session_attached}|#{session_name}' -s " + Quote(name);
        if (!string.IsNullOrWhiteSpace(directory)) command += " -c " + Quote(directory);
        return ParseSessions(await ExecuteAsync(command, token)).Single();
    }
    public async Task<string?> SessionForClientAsync(string tty)
    {
        if (!ProcessTable.IsDevice(tty)) throw new IOException("Invalid terminal device.");
        var output = await ExecuteAsync("tmux list-clients -F '#{client_tty}|#{session_id}' 2>/dev/null || true");
        var match = output.Split('\n').Select(line => line.TrimEnd('\r').Split('|', 2)).FirstOrDefault(p => p.Length == 2 && p[0] == tty);
        if (match is null) return null;
        SessionId(match[1]); return match[1];
    }
    public static IReadOnlyList<TmuxSessionInfo> ParseSessions(string text) => text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(line =>
    {
        var parts = line.TrimEnd('\r').Split('|', 3);
        if (parts.Length != 3 || !uint.TryParse(parts[1], out var attached)) throw new IOException("Unreadable tmux session response.");
        SessionId(parts[0]); return new TmuxSessionInfo(parts[0], parts[2], attached > 0, []);
    }).ToArray();
    public static IReadOnlyList<TmuxWindow> ParseWindows(string text) => text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(line =>
    {
        var p = line.TrimEnd('\r').Split('|', 5);
        if (p.Length != 5 || !p[0].StartsWith('@') || !uint.TryParse(p[0][1..], out var id) || !uint.TryParse(p[1], out var index) ||
            !uint.TryParse(p[2], out var active) || !uint.TryParse(p[3], out var panes)) throw new IOException("Unreadable tmux window response.");
        return new TmuxWindow(id, index, p[4], active != 0, panes);
    }).ToArray();
    public static string SessionId(string id) => id.Length is > 1 and < 21 && id[0] == '$' && id[1..].All(char.IsAsciiDigit) ? Quote(id) : throw new IOException("Invalid tmux session identifier.");
    public static string Quote(string value) => value.Length <= 1024 && !value.Any(char.IsControl) ? "'" + value.Replace("'", "'\\''") + "'" : throw new IOException("Invalid command argument.");
    public async ValueTask DisposeAsync()
    {
        if (_lifetime.IsCancellationRequested) return;
        _lifetime.Cancel();
        try { await BoundedProcess.RunAsync(Program, ["--distribution", Distribution, "--exec", "rm", "-f", _marker], timeoutSeconds: 3); }
        catch { /* An unavailable distribution must not keep the window open. */ }
        _lifetime.Dispose();
    }
}
