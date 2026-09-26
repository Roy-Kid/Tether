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
            }
        }
        catch (Exception)
        {
            Current = new AppSettings();
        }
    }

    public bool Save()
    {
        Current = this;
        Changed?.Invoke();
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
