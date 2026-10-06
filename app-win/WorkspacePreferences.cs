namespace TetherApp;

public sealed record WorkspaceCommand(string Id, string Title, string DefaultShortcut);

public static class WorkspaceCommands
{
    public static IReadOnlyList<WorkspaceCommand> All { get; } =
    [
        new("newTerminal", "New Terminal", "Ctrl+Shift+T"),
        new("changeHost", "Change Host", "Ctrl+Shift+H"),
        new("closeTab", "Close Tab", "Ctrl+Shift+W"),
        new("restoreTab", "Restore Tab", "Ctrl+Shift+R"),
        new("commandMenu", "Command Menu", "Ctrl+Shift+P"),
        new("quickSwitch", "Quick Switch", "Ctrl+P"),
        new("inspector", "Inspector", "Ctrl+Shift+I"),
        new("toggleTabBar", "Toggle Tab Bar", "Ctrl+Shift+S"),
        new("zen", "Zen Mode", "Ctrl+Shift+Z"),
        new("previousTab", "Previous Tab", "Ctrl+PageUp"),
        new("nextTab", "Next Tab", "Ctrl+PageDown"),
        new("renameTerminal", "Rename Terminal", "Ctrl+Shift+N"),
        new("manageHosts", "Manage Hosts", ""),
        new("manageIdentities", "Manage Identities", ""),
    ];

    public static string Binding(WorkspaceCommand command, AppSettings settings) =>
        settings.KeyBindings.TryGetValue(command.Id, out var chord) ? chord : command.DefaultShortcut;

    public static string? Validate(IReadOnlyDictionary<string, string> bindings, TerminalPreferences terminal)
    {
        var seen = terminal.Bindings.Select(b => { Shortcut.TryParse(b.Chord, out var key); return key; }).ToHashSet();
        foreach (var command in All)
        {
            var chord = bindings.TryGetValue(command.Id, out var custom) ? custom : command.DefaultShortcut;
            if (string.IsNullOrWhiteSpace(chord)) continue;
            if (!Shortcut.TryParse(chord, out var key)) return $"Invalid shortcut for {command.Title}.";
            if (!seen.Add(key)) return $"Shortcut for {command.Title} is already assigned.";
        }
        foreach (var (id, chord) in bindings.Where(b => !All.Any(c => c.Id == b.Key)))
        {
            if (string.IsNullOrWhiteSpace(chord)) continue;
            if (!Shortcut.TryParse(chord, out var key)) return $"Invalid shortcut for {id}.";
            if (!seen.Add(key)) return $"Shortcut for {id} is already assigned.";
        }
        return null;
    }
}
