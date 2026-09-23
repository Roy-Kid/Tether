// Semantic keys, never bytes.
//
// The contract is the same one `KeyCapture*.swift` honours on Apple: a
// frontend reports a `TerminalInput` key, not an encoded sequence, because
// encoding depends on modes only the engine knows (spec §12). Ctrl-C sends
// the letter `c` with `Control` set; the engine applies the chord. Option-as-
// Meta sends the letter with `Alt` set rather than the character the layout
// would produce.

using Windows.System;

namespace Tether;

/// <summary>Maps a WinUI/VirtualKey press to a semantic <see cref="TerminalInput"/>.</summary>
public static class KeyInput
{
    /// <summary>
    /// Builds the input for a key press, or <c>null</c> when the chord is the
    /// application's (Win/⌘-chords, Alt+F4) and must not reach the terminal.
    /// </summary>
    /// <param name="key">The virtual key.</param>
    /// <param name="shift">Whether Shift is down.</param>
    /// <param name="alt">Whether Alt (Option) is down.</param>
    /// <param name="control">Whether Control is down.</param>
    /// <param name="text">
    /// The composed text for a character key, when the platform already knows
    /// it (IME, `KeyDown` with a character). Multi-scalar graphemes survive
    /// because this is a string.
    /// </param>
    public static TerminalInput? FromVirtualKey(
        VirtualKey key, bool shift, bool alt, bool control, string? text = null)
    {
        // Application chords stay with the application.
        if (!control && !alt && IsWindowsChord(key))
            return null;

        var modifiers = new KeyModifiers(shift, alt, control);

        // A composed character wins over the virtual key: IME and dead keys
        // arrive as text, and a string may carry several scalars.
        if (!control && !alt && !string.IsNullOrEmpty(text) && IsTextKey(key, text!))
            return new TerminalInput.Key(new KeyPress.Char(text!), modifiers);

        return MapNamed(key, modifiers);
    }

    /// <summary>Maps a paste.</summary>
    public static TerminalInput Paste(string text) => new TerminalInput.Paste(text);

    /// <summary>
    /// Whether this chord should move the scrollback rather than reach the
    /// remote. Copied from `SessionModel.swift`: Shift+PageUp/PageDown/Home/End
    /// are stolen before <c>Send</c>.
    /// </summary>
    public static ScrollTo? ScrollChord(VirtualKey key, bool shift, bool control, bool alt)
    {
        if (!shift || control || alt) return null;
        return key switch
        {
            VirtualKey.PageUp => ScrollTo.PageBack,
            VirtualKey.PageDown => ScrollTo.Page,
            VirtualKey.Home => ScrollTo.Oldest,
            VirtualKey.End => ScrollTo.Live,
            _ => null,
        };
    }

    private static bool IsWindowsChord(VirtualKey key) => key == VirtualKey.LeftWindows
        || key == VirtualKey.RightWindows
        || key == VirtualKey.Application;

    private static bool IsTextKey(VirtualKey key, string text) => text.Length > 0 && key switch
    {
        VirtualKey.Enter => text is "\r" or "\n",
        VirtualKey.Tab => text == "\t",
        VirtualKey.Back => false,
        VirtualKey.Escape => false,
        VirtualKey.Delete => false,
        VirtualKey.Up or VirtualKey.Down or VirtualKey.Left or VirtualKey.Right => false,
        VirtualKey.Home or VirtualKey.End or VirtualKey.PageUp or VirtualKey.PageDown => false,
        VirtualKey.Insert => false,
        _ => true,
    };

    private static TerminalInput Key(KeyPress press, KeyModifiers modifiers) =>
        new TerminalInput.Key(press, modifiers);

    private static TerminalInput? MapNamed(VirtualKey key, KeyModifiers modifiers) => key switch
    {
        VirtualKey.Enter => Key(new KeyPress.Enter(), modifiers),
        VirtualKey.Tab => Key(new KeyPress.Tab(), modifiers),
        VirtualKey.Back => Key(new KeyPress.Backspace(), modifiers),
        VirtualKey.Escape => Key(new KeyPress.Escape(), modifiers),
        VirtualKey.Delete => Key(new KeyPress.Delete(), modifiers),
        VirtualKey.Insert => Key(new KeyPress.Insert(), modifiers),
        VirtualKey.Up => Key(new KeyPress.Up(), modifiers),
        VirtualKey.Down => Key(new KeyPress.Down(), modifiers),
        VirtualKey.Left => Key(new KeyPress.Left(), modifiers),
        VirtualKey.Right => Key(new KeyPress.Right(), modifiers),
        VirtualKey.Home => Key(new KeyPress.Home(), modifiers),
        VirtualKey.End => Key(new KeyPress.End(), modifiers),
        VirtualKey.PageUp => Key(new KeyPress.PageUp(), modifiers),
        VirtualKey.PageDown => Key(new KeyPress.PageDown(), modifiers),
        >= VirtualKey.F1 and <= VirtualKey.F24 =>
            Key(new KeyPress.Function((byte)(key - VirtualKey.F1 + 1)), modifiers),
        // A letter with Control still sends the letter: the engine applies the
        // chord against the remote's modes. Without a composed string this is
        // the best we have.
        >= VirtualKey.A and <= VirtualKey.Z =>
            Key(new KeyPress.Char(((char)('a' + (key - VirtualKey.A))).ToString()), modifiers),
        >= VirtualKey.Number0 and <= VirtualKey.Number9 =>
            Key(new KeyPress.Char(((char)('0' + (key - VirtualKey.Number0))).ToString()), modifiers),
        >= VirtualKey.NumberPad0 and <= VirtualKey.NumberPad9 =>
            Key(new KeyPress.Char(((char)('0' + (key - VirtualKey.NumberPad0))).ToString()), modifiers),
        _ => null,
    };
}
