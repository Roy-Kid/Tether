// What this machine is set to open.
//
// A person's shell is a preference, not an SDK fact: the same binary has to
// be able to open PowerShell on one machine and `cmd` on another. Stored
// beside the person's other Tether state, not in the SDK.

using System.Text.Json;

namespace TetherApp;

public sealed record AppSettings(
    string Shell = "pwsh",
    bool OpenLocalOnStart = true)
{
    public static AppSettings Current { get; private set; } = new();

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
            }
        }
        catch (Exception)
        {
            Current = new AppSettings();
        }
    }

    public void Save()
    {
        Current = this;
        try
        {
            var dir = System.IO.Path.GetDirectoryName(SettingsPath);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(this));
        }
        catch (Exception)
        {
            // A settings file that cannot be written is not a session
            // failure. The choice applies to this run either way.
        }
    }

    /// <summary>The shells this machine is likely to have, best first.</summary>
    public static IReadOnlyList<(string Program, string Name)> KnownShells { get; } =
    [
        ("pwsh", "PowerShell 7"),
        ("powershell", "Windows PowerShell"),
        ("cmd", "Command Prompt"),
    ];
}
