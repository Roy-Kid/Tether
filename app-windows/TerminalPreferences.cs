using Windows.System;

namespace TetherApp;

public sealed record TerminalPreferences
{
    public string FontFamily { get; init; } = "Consolas";
    public string WideFontFamily { get; init; } = "Microsoft YaHei UI";
    public double FontSize { get; init; } = 13;
    public int PasteThreshold { get; init; } = 4096;
    public string Copy { get; init; } = "Ctrl+Shift+C";
    public string Paste { get; init; } = "Ctrl+Shift+V";
    public string ZoomIn { get; init; } = "Ctrl+Shift+Equals";
    public string ZoomOut { get; init; } = "Ctrl+Minus";
    public string ZoomReset { get; init; } = "Ctrl+0";

    [System.Text.Json.Serialization.JsonIgnore]
    public IEnumerable<(string Name, string Chord)> Bindings =>
        [("Copy", Copy), ("Paste", Paste), ("Zoom in", ZoomIn), ("Zoom out", ZoomOut), ("Reset zoom", ZoomReset)];

    public string? Validate()
    {
        if (string.IsNullOrWhiteSpace(FontFamily) || string.IsNullOrWhiteSpace(WideFontFamily)) return "Choose a font for both text and wide characters.";
        if (!double.IsFinite(FontSize) || FontSize is < 10 or > 32) return "Font size must be between 10 and 32.";
        if (PasteThreshold is < 1 or > 1000000) return "Paste threshold must be between 1 and 1,000,000 characters.";
        var seen = new HashSet<Shortcut>();
        foreach (var (name, chord) in Bindings)
        {
            if (!Shortcut.TryParse(chord, out var shortcut)) return $"Invalid shortcut for {name}. Use Ctrl+Shift+C, Ctrl+Minus or Ctrl+0.";
            if (!seen.Add(shortcut)) return "Each action needs a different shortcut.";
        }
        return null;
    }

    public bool ConfirmPaste(string text) => text.Length >= PasteThreshold || text.Contains('\n') || text.Contains('\r');
}

public readonly record struct Shortcut(VirtualKey Key, bool Shift, bool Control, bool Alt)
{
    public static bool TryParse(string? value, out Shortcut result)
    {
        result = default;
        if (string.IsNullOrWhiteSpace(value)) return false;
        var parts = value.Split('+', StringSplitOptions.TrimEntries);
        var modifiers = parts[..^1].Select(p => p.ToLowerInvariant()).ToArray();
        if (modifiers.Length == 0 || modifiers.Distinct().Count() != modifiers.Length ||
            modifiers.Any(p => p is not ("ctrl" or "shift" or "alt"))) return false;
        var ctrl = modifiers.Contains("ctrl");
        var alt = modifiers.Contains("alt");
        // Ctrl+Alt is AltGr on many keyboard layouts.
        if ((!ctrl && !alt) || (ctrl && alt)) return false;
        var name = parts[^1].ToUpperInvariant();
        VirtualKey key;
        if (name.Length == 1 && char.IsAsciiLetterOrDigit(name[0])) key = (VirtualKey)name[0];
        else if (name == "EQUALS") key = (VirtualKey)187;
        else if (name == "MINUS") key = (VirtualKey)189;
        else return false;
        result = new(key, modifiers.Contains("shift"), ctrl, alt);
        return true;
    }
}
