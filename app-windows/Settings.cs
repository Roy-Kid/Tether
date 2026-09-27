// What this machine is set to open.
//
// A person's shell is a preference, not an SDK fact: the same binary has to
// be able to open PowerShell on one machine and `cmd` on another. Stored
// beside the person's other Tether state, not in the SDK.

using System.Text.Json;

namespace TetherApp;

public sealed record AppSettings(string Shell = "pwsh", string Appearance = "system")
{
    /// <summary>Plugin ids a person has switched off. Missing in an old file means none.</summary>
    public string[] DisabledPlugins { get; init; } = [];
    public TerminalPreferences Terminal { get; init; } = new();

    /// <summary>
    /// The <c>ssh.exe</c> used to attach to an existing OpenSSH connection.
    /// Empty is Windows OpenSSH under <c>System32</c> when that file exists.
    /// </summary>
    public string SshProgram { get; init; } = "";

    public static AppSettings Current { get; private set; } = new();
    public static event Action? Changed;

    public static string SettingsPath
    {
        get
        {
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            return System.IO.Path.Combine(appData, "Tether", "settings.json");
        }
    }

    public static void Load()
    {
        try
        {
            if (File.Exists(SettingsPath))
            {
                var text = File.ReadAllText(SettingsPath);
                Current = JsonSerializer.Deserialize<AppSettings>(text) ?? new AppSettings();
                if (string.IsNullOrWhiteSpace(Current.Shell)) Current = new AppSettings();
                if (Current.Terminal is null || Current.Terminal.Validate() is not null)
                    Current = Current with { Terminal = new() };
            }
        }
        catch (Exception)
        {
            Current = new AppSettings();
        }
        PublishSshProgram();
    }

    /// <summary>
    /// The ssh binary a master check and an attach will exec. A blank
    /// setting is <c>C:\Windows\System32\OpenSSH\ssh.exe</c> when it is there.
    /// </summary>
    public static string ResolveSshProgram(string? configured = null)
    {
        var chosen = (configured ?? Current.SshProgram).Trim();
        if (chosen.Length > 0) return chosen;
        var system = Path.Combine(Environment.SystemDirectory, "OpenSSH", "ssh.exe");
        if (File.Exists(system)) return system;
        return "ssh";
    }

    /// <summary>Known ssh binaries on this machine, Windows OpenSSH first.</summary>
    public static IReadOnlyList<(string Path, string Name)> KnownSshPrograms()
    {
        var found = new List<(string Path, string Name)>();
        var system = Path.Combine(Environment.SystemDirectory, "OpenSSH", "ssh.exe");
        if (File.Exists(system)) found.Add((system, "Windows OpenSSH"));
        foreach (var root in new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
        })
        {
            if (string.IsNullOrEmpty(root)) continue;
            var git = Path.Combine(root, "Git", "usr", "bin", "ssh.exe");
            if (File.Exists(git)) found.Add((git, "Git OpenSSH"));
        }
        return found;
    }

    private static void PublishSshProgram() =>
        Environment.SetEnvironmentVariable("TETHER_SSH", ResolveSshProgram());

    public bool Save()
    {
        Current = this;
        Changed?.Invoke();
        PublishSshProgram();
        try
        {
            var dir = System.IO.Path.GetDirectoryName(SettingsPath);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(this));
            return true;
        }
        catch (Exception)
        {
            // The selection still applies to this run; the UI reports failed persistence.
            return false;
        }
    }

    /// <summary>The shells this machine is likely to have, best first.</summary>
    public static IReadOnlyList<(string Program, string Name)> KnownShells { get; } =
    [
        ("pwsh", "PowerShell"),
        ("powershell", "Windows PowerShell"),
        ("cmd", "Command Prompt (cmd)"),
        ("wsl", "WSL"),
    ];

    public static string ResolveShellProgram(string shell)
    {
        if (shell == "powershell")
            return Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
        if (shell is "cmd" or "wsl")
        {
            var systemProgram = Path.Combine(Environment.SystemDirectory, shell + ".exe");
            if (File.Exists(systemProgram)) return systemProgram;
            throw new FileNotFoundException($"{shell} is not installed. Choose another default profile in Settings.");
        }
        if (Path.IsPathRooted(shell) && File.Exists(shell)) return shell;
        var executable = Path.HasExtension(shell) ? shell : shell + ".exe";
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            if (string.IsNullOrWhiteSpace(directory)) continue;
            var candidate = Path.Combine(directory.Trim().Trim('"'), executable);
            if (File.Exists(candidate)) return Path.GetFullPath(candidate);
        }
        if (shell == "pwsh") return ResolveShellProgram("powershell");
        throw new FileNotFoundException($"Shell '{shell}' was not found. Choose another default profile in Settings.");
    }
}
