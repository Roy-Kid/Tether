namespace TetherApp;

public sealed record WorkspaceCommand(string Id, string Title, string DefaultShortcut, string Group = "Workspace",
    string SecondaryShortcut = "");

public sealed record WorkspaceCommandState(int Tabs, int Terminals, int VisibleTerminals, bool Live,
    bool CanReconnect, bool CanRestore, bool Busy, bool SplitRight, bool SplitDown, bool Zen, bool Inspectors,
    bool Extension = false);

public static class WorkspaceCommands
{
    public static IReadOnlyList<WorkspaceCommand> All { get; } =
    [
        new("newTerminal", "New Terminal", "Ctrl+Shift+N"),
        new("newTab", "New Tab", "Ctrl+Shift+T"),
        new("changeHost", "Change Host", "Ctrl+Shift+H"),
        new("closeTab", "Close Terminal", "Ctrl+Shift+W"),
        new("closeWorkspace", "Close Tab", "Alt+Shift+W"),
        new("closeWindow", "Close Window", ""),
        new("splitRight", "Split Left/Right", "Ctrl+Shift+D"),
        new("splitDown", "Split Top/Bottom", "Ctrl+Shift+E"),
        new("maximizePane", "Maximize/Restore Pane", "Ctrl+Shift+Enter"),
        new("joinGroups", "Join All Splits", ""),
        new("previousTerminal", "Previous Terminal", "Alt+Up"),
        new("nextTerminal", "Next Terminal", "Alt+Down"),
        new("reconnect", "Reconnect", ""),
        new("focusLeft", "Focus Left Pane", "Alt+Shift+Left"),
        new("focusRight", "Focus Right Pane", "Alt+Shift+Right"),
        new("focusUp", "Focus Upper Pane", "Alt+Shift+Up"),
        new("focusDown", "Focus Lower Pane", "Alt+Shift+Down"),
        new("restoreTab", "Reopen Closed Tab", "Ctrl+Shift+R"),
        new("commandMenu", "Command Palette", "Ctrl+Shift+P", SecondaryShortcut: "Alt+Shift+P"),
        new("quickSwitch", "Quick Switch", "Ctrl+P"),
        new("inspector", "Inspector", "Ctrl+Shift+I"),
        new("toggleTabBar", "Toggle Tab Bar", "Ctrl+Shift+S"),
        new("zen", "Zen Mode", "Ctrl+Shift+Z"),
        new("previousTab", "Previous Tab", "Ctrl+PageUp"),
        new("nextTab", "Next Tab", "Ctrl+PageDown"),
        new("renameTerminal", "Rename Terminal", ""),
        new("renameTab", "Rename Tab", ""),
        new("manageHosts", "Manage Hosts", ""),
        new("manageIdentities", "Manage Identities", ""),
        new("settings", "Settings", ""),
    ];

    public static bool IsEnabled(string id, WorkspaceCommandState state) => id switch
    {
        "newTerminal" or "newTab" or "restoreTab" => !state.Busy && (id != "restoreTab" || state.CanRestore),
        "closeTab" => (state.Terminals > 0 || state.Extension) && !state.Busy,
        "closeWorkspace" or "renameTerminal" or "renameTab" => state.Terminals > 0 && !state.Busy,
        "previousTab" or "nextTab" => state.Tabs > 1,
        "previousTerminal" or "nextTerminal" => state.Terminals > 1,
        "splitRight" => state.Live && state.SplitRight && !state.Busy,
        "splitDown" => state.Live && state.SplitDown && !state.Busy,
        "maximizePane" or "joinGroups" => state.VisibleTerminals > 1,
        "focusLeft" or "focusRight" or "focusUp" or "focusDown" => state.VisibleTerminals > 1,
        "reconnect" => state.CanReconnect && !state.Busy,
        "inspector" => state.Terminals > 0 && state.Inspectors && !state.Zen,
        _ => true,
    };

    public static bool AnswersWhileEditing(string id) => id is "commandMenu" or "quickSwitch";

    public static string Binding(WorkspaceCommand command, AppSettings settings) =>
        settings.KeyBindings.TryGetValue(command.Id, out var chord) ? chord : command.DefaultShortcut;

    public static string SecondaryBinding(WorkspaceCommand command, AppSettings settings) =>
        settings.KeyBindings.TryGetValue(SecondaryKey(command.Id), out var chord) ? chord : command.SecondaryShortcut;

    public static string SecondaryKey(string id) => id + ".secondary";

    public static IEnumerable<string> Bindings(WorkspaceCommand command, AppSettings settings)
    {
        var primary = Binding(command, settings);
        if (!string.IsNullOrWhiteSpace(primary)) yield return primary;
        var secondary = SecondaryBinding(command, settings);
        if (!string.IsNullOrWhiteSpace(secondary)) yield return secondary;
    }

    public static bool Matches(WorkspaceCommand command, AppSettings settings, Shortcut shortcut) =>
        Bindings(command, settings).Any(chord => Shortcut.TryParse(chord, out var key) && key == shortcut);

    public static string? Validate(IReadOnlyDictionary<string, string> bindings, TerminalPreferences terminal)
    {
        var seen = terminal.Bindings.Select(b => { Shortcut.TryParse(b.Chord, out var key); return key; }).ToHashSet();
        foreach (var command in All)
        {
            foreach (var (label, chord) in new[]
            {
                ("", bindings.TryGetValue(command.Id, out var primary) ? primary : command.DefaultShortcut),
                (" (secondary)", bindings.TryGetValue(SecondaryKey(command.Id), out var secondary) ? secondary : command.SecondaryShortcut),
            })
            {
                if (string.IsNullOrWhiteSpace(chord)) continue;
                if (!Shortcut.TryParse(chord, out var key)) return $"Invalid shortcut for {command.Title}{label}.";
                if (!seen.Add(key)) return $"Shortcut for {command.Title}{label} is already assigned.";
            }
        }
        foreach (var (id, chord) in bindings.Where(b => !All.Any(c => c.Id == b.Key || SecondaryKey(c.Id) == b.Key)))
        {
            if (string.IsNullOrWhiteSpace(chord)) continue;
            if (!Shortcut.TryParse(chord, out var key)) return $"Invalid shortcut for {id}.";
            if (!seen.Add(key)) return $"Shortcut for {id} is already assigned.";
        }
        return null;
    }
}
