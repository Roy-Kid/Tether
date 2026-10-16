// The contract a UI author draws against.
//
// Mirrors the Swift façade's naming rather than UniFFI's generated names, and
// keeps every UniFFI type `internal` (spec §8: no UI toolkit types here, and
// Decisions/0004: generated symbols must not leak). A consumer that needs a
// type that is not exported here has found a façade gap, not a reason to
// reach into `Generated/`.

namespace Tether;

/// <summary>One of the palette entries a terminal names rather than resolves.</summary>
/// <remarks>
/// Still named at the boundary: the consumer owns the palette (Decision 0011),
/// and a light theme must be free to draw "red" as its own red.
/// </remarks>
public enum ColorName
{
    Black, Red, Green, Yellow, Blue, Magenta, Cyan, White,
    BrightBlack, BrightRed, BrightGreen, BrightYellow,
    BrightBlue, BrightMagenta, BrightCyan, BrightWhite,
    Foreground, Background, Cursor,
}

/// <summary>How a cell's colour is specified.</summary>
public abstract record CellColor
{
    public sealed record Named(ColorName Name) : CellColor;
    public sealed record Indexed(byte Index) : CellColor;
    public sealed record Rgb(byte Red, byte Green, byte Blue) : CellColor;
}

public enum UnderlineStyle { None, Single, Double, Curly, Dotted, Dashed }

/// <summary>
/// What the caret looks like. <see cref="Hidden"/> is a shape as well as a
/// flag: a full-screen program hides the cursor constantly while redrawing,
/// and drawing it anyway is how a terminal ends up with a block flickering
/// across the screen.
/// </summary>
public enum CaretShape { Block, Underline, Beam, Hidden }

/// <summary>Everything about a run's appearance except its text.</summary>
public sealed record RunStyle(
    CellColor Foreground,
    CellColor Background,
    UnderlineStyle Underline = UnderlineStyle.None,
    CellColor? UnderlineColor = null,
    bool Bold = false,
    bool Dim = false,
    bool Italic = false,
    bool Strikethrough = false,
    bool Inverse = false,
    bool Hidden = false)
{
    public static readonly RunStyle Default = new(
        new CellColor.Named(ColorName.Foreground),
        new CellColor.Named(ColorName.Background));
}

/// <summary>
/// A stretch of text on one row that looks the same all the way along, every
/// character of it covering the same number of columns.
/// </summary>
/// <param name="Text">The graphemes, as one string.</param>
/// <param name="Columns">
/// How many columns the run covers. Not <c>Text.Length</c> — a wide character
/// is one grapheme over two columns.
/// </param>
public sealed record StyledRun(string Text, uint Columns, RunStyle Style);

public sealed record ScreenRow(StyledRun[] Runs);

/// <summary>One frame: everything a frontend needs to draw the screen once.</summary>
public sealed record ScreenFrame(
    uint Columns,
    uint Rows,
    uint CursorRow,
    uint CursorColumn,
    CaretShape CursorShape,
    bool CursorVisible,
    bool AlternateScreen,
    uint ViewportOffset,
    uint HistoryLines,
    string Title,
    ScreenRow[] Lines)
{
    public MouseTracking Mouse { get; init; }
}

/// <summary>Modifier keys. No "command": Apple's Option maps to Alt.</summary>
public sealed record KeyModifiers(bool Shift = false, bool Alt = false, bool Control = false);

/// <summary>A semantic key press. <c>Char</c> carries a string, not a char.</summary>
/// <remarks>
/// Multi-scalar graphemes (composed text) must survive, which is why this is
/// a string (spec §12). Encoding to bytes is the engine's job, against the
/// modes the remote program set.
/// </remarks>
public abstract record KeyPress
{
    public sealed record Char(string Text) : KeyPress;
    public sealed record Enter() : KeyPress;
    public sealed record Tab() : KeyPress;
    public sealed record Backspace() : KeyPress;
    public sealed record Escape() : KeyPress;
    public sealed record Delete() : KeyPress;
    public sealed record Insert() : KeyPress;
    public sealed record Up() : KeyPress;
    public sealed record Down() : KeyPress;
    public sealed record Left() : KeyPress;
    public sealed record Right() : KeyPress;
    public sealed record Home() : KeyPress;
    public sealed record End() : KeyPress;
    public sealed record PageUp() : KeyPress;
    public sealed record PageDown() : KeyPress;
    public sealed record Function(byte Number) : KeyPress;
}

/// <summary>Something the person did.</summary>
public abstract record TerminalInput
{
    /// <param name="Press">The key. Named <c>Press</c>, not <c>Key</c>, because the nested type is already <c>Key</c>.</param>
    public sealed record Key(KeyPress Press, KeyModifiers Modifiers) : TerminalInput;
    public sealed record Paste(string Text) : TerminalInput;
    public sealed record Pointer(PointerButton Button, PointerPhase Phase, ushort Column, ushort Row, KeyModifiers Modifiers) : TerminalInput;
}

public enum MouseTracking { Off, Clicks, Drag, Any }
public enum PointerButton { Left, Middle, Right, None, WheelUp, WheelDown }
public enum PointerPhase { Press, Release, Move }

public enum ScrollToKind { Lines, PageUp, PageDown, Oldest, Live }

public sealed record ScrollTo(ScrollToKind Kind, int LineCount = 0)
{
    public static readonly ScrollTo Page = new(ScrollToKind.PageDown);
    public static readonly ScrollTo PageBack = new(ScrollToKind.PageUp);
    public static readonly ScrollTo Oldest = new(ScrollToKind.Oldest);
    public static readonly ScrollTo Live = new(ScrollToKind.Live);
    public static ScrollTo Lines(int count) => new(ScrollToKind.Lines, count);
}

public abstract record SessionEnding
{
    public sealed record Exited(uint Status) : SessionEnding;
    public sealed record Closed() : SessionEnding;
    public sealed record Lost(string Cause) : SessionEnding;
}

/// <summary>
/// One hop in front of a <see cref="Destination"/>. Authenticated on its own,
/// with its own secrets — a password for the destination is not offered here.
/// </summary>
public sealed record Jump(string Host, ushort Port, string User, IReadOnlyList<Secret> Secrets);

/// <summary>Where a shell is going.</summary>
public sealed record Destination(
    string Host,
    ushort Port,
    string User,
    string Term = "xterm-256color",
    ushort Columns = 80,
    ushort Rows = 24,
    uint ScrollbackLines = 10_000,
    SessionHistory? History = null);

/// <summary>What the server presented as its identity.</summary>
/// <param name="Fingerprint">The <c>SHA256:…</c> form a person compares against what their administrator published.</param>
/// <param name="Encoded">
/// The <c>authorized_keys</c> one-line form, which is what a <c>known_hosts</c>
/// file holds after the host pattern. A verifier that stores keys rather than
/// fingerprints needs this.
/// </param>
public sealed record HostIdentity(
    string Host,
    ushort Port,
    string Algorithm,
    string Fingerprint,
    byte[] Encoded);

/// <summary>
/// Asks the application whether a host may be talked to. Called during the
/// handshake, before any credential exists on the wire (spec §18).
/// </summary>
public interface IHostTrust
{
    Task<bool> TrustsAsync(HostIdentity host, CancellationToken cancellationToken = default);
}

/// <summary>One question an SSH server asks during keyboard-interactive auth.</summary>
/// <param name="Echo">
/// False for anything that must not be shown while typed — a password, a
/// one-time code. Honour it.
/// </param>
public sealed record AuthPrompt(string Text, bool Echo);

/// <summary>
/// Answers the questions a server asks. The server decides how many rounds
/// there are and what it asks; neither is known in advance, which is why this
/// is a conversation rather than a credential handed over once.
/// </summary>
public interface IAuthPrompter
{
    /// <summary>Returns one answer per prompt, in order. Empty means declined.</summary>
    Task<IReadOnlyList<string>> AnswerAsync(
        string instruction, IReadOnlyList<AuthPrompt> prompts, CancellationToken cancellationToken = default);
}

/// <summary>A credential, offered in order.</summary>
public abstract record Secret
{
    public sealed record Password(string Value) : Secret;
    public sealed record PrivateKey(string Pem, string? Passphrase = null, IPassphrasePrompter? Unlock = null) : Secret;
    public sealed record Interactive(IAuthPrompter Prompter) : Secret;
}

/// <summary>
/// Sixteen ANSI colours plus foreground, background and cursor. Exactly
/// sixteen ANSI entries — any other length is refused rather than padded
/// (Decision 0011).
/// </summary>
public sealed record TerminalPalette(
    ColorValue Foreground,
    ColorValue Background,
    ColorValue Cursor,
    IReadOnlyList<ColorValue> Ansi)
{
    public static TerminalPalette FromRgba(
        (byte R, byte G, byte B) foreground,
        (byte R, byte G, byte B) background,
        (byte R, byte G, byte B) cursor,
        IReadOnlyList<(byte R, byte G, byte B)> ansi)
    {
        if (ansi.Count != 16)
            throw new ArgumentException("a palette is sixteen ANSI colours, not " + ansi.Count, nameof(ansi));
        return new TerminalPalette(
            new ColorValue(foreground.R, foreground.G, foreground.B),
            new ColorValue(background.R, background.G, background.B),
            new ColorValue(cursor.R, cursor.G, cursor.B),
            ansi.Select(c => new ColorValue(c.R, c.G, c.B)).ToArray());
    }
}

public sealed record ColorValue(byte Red, byte Green, byte Blue);

/// <summary>A cell on the grid.</summary>
public readonly record struct Cell(int Column, int Row);

/// <summary>Where a link is drawn on one screen row. <c>End</c> is one past the last column.</summary>
public sealed record LinkSpan(int Row, int Start, int End);

/// <summary>What a link points at. A path is shape, not truth (Decisions/0015).</summary>
public abstract record LinkKind
{
    /// <summary>The URI a program attached with <c>OSC 8</c>, exactly as sent.</summary>
    public sealed record Hyperlink(string Uri) : LinkKind;

    /// <summary>A web address. <c>Href</c>, not <c>Url</c>: the nested type is already <c>Url</c>.</summary>
    public sealed record Url(string Href) : LinkKind;

    /// <summary>Relative or absolute, as printed; <c>Line</c>/<c>Column</c> when it carried <c>:12:5</c>.</summary>
    public sealed record Path(string Location, int? Line, int? Column) : LinkKind;
}

/// <summary>Something on screen that names a place, and where it is drawn.</summary>
public sealed record TerminalLink(string Text, LinkKind Kind, IReadOnlyList<LinkSpan> Spans);

/// <summary>What the pointer is doing (spec §14 carries selection; Decisions/0015 adds link underlines).</summary>
public sealed record Overlay(
    Selection? Selection,
    IReadOnlyList<LinkUnderline> LinkUnderlines,
    Rgba SelectionColor,
    Rgba LinkColor)
{
    public static Overlay Empty { get; } = new(
        null,
        Array.Empty<LinkUnderline>(),
        new Rgba(0.3f, 0.55f, 1f, 0.12f),
        new Rgba(0.3f, 0.55f, 1f, 1f));
}

/// <summary>A drag selection, as the two cells the drag started and ended on.</summary>
public sealed record Selection(Cell Anchor, Cell Focus);

/// <summary>One underline under a hovered link. A wrapped link is several (Decisions/0015).</summary>
/// <param name="End">One past the last column.</param>
public sealed record LinkUnderline(int Row, int Start, int End, bool Confirmed);

/// <summary>Errors are ours. Backend error numbers never reach this type (spec §18).</summary>
public abstract class TetherException : Exception
{
    protected TetherException(string message, Exception? inner = null) : base(message, inner) { }

    public sealed class Cancelled : TetherException
    {
        public Cancelled() : base("cancelled") { }
    }

    public sealed class TimedOut : TetherException
    {
        public TimedOut(ulong millis) : base($"timed out after {millis}ms") => Millis = millis;
        public ulong Millis { get; }
    }

    public sealed class Unreachable : TetherException
    {
        public Unreachable(string endpoint, string cause) : base($"{endpoint}: {cause}")
        {
            Endpoint = endpoint; Cause = cause;
        }
        public string Endpoint { get; }
        public string Cause { get; }
    }

    public sealed class HostRejected : TetherException
    {
        public HostRejected(string endpoint) : base($"{endpoint}: host rejected") => Endpoint = endpoint;
        public string Endpoint { get; }
    }

    public sealed class AuthenticationFailed : TetherException
    {
        public AuthenticationFailed(IReadOnlyList<string> remaining, IReadOnlyList<SkippedKey>? skipped = null)
            : base("authentication failed; still accepted: " + string.Join(", ", remaining) +
                (skipped is { Count: > 0 } ? "; " + string.Join("; ", skipped.Select(k => k.Reason)) : ""))
        { Remaining = remaining; Skipped = skipped ?? []; }
        public IReadOnlyList<string> Remaining { get; }
        public IReadOnlyList<SkippedKey> Skipped { get; }
    }

    public sealed class MoreFactorsNeeded : TetherException
    {
        public MoreFactorsNeeded(IReadOnlyList<string> remaining)
            : base("more factors needed: " + string.Join(", ", remaining))
            => Remaining = remaining;
        public IReadOnlyList<string> Remaining { get; }
    }

    public sealed class NothingToOffer : TetherException
    {
        public NothingToOffer() : base("nothing to offer") { }
    }

    public sealed class ShellRefused : TetherException
    {
        public ShellRefused(string cause) : base($"shell refused: {cause}") => Cause = cause;
        public string Cause { get; }
    }

    public sealed class Unsupported : TetherException
    {
        public Unsupported(string what) : base($"unsupported: {what}") => What = what;
        public string What { get; }
    }

    public sealed class Disconnected : TetherException
    {
        public Disconnected(string cause) : base($"disconnected: {cause}") => Cause = cause;
        public string Cause { get; }
    }

    public sealed class SessionEnded : TetherException
    {
        public SessionEnded() : base("session ended") { }
    }

    public sealed class Protocol : TetherException
    {
        public Protocol(string cause) : base($"protocol: {cause}") => Cause = cause;
        public string Cause { get; }
    }
}

public sealed record TmuxWindow(uint Id, uint Index, string Name, bool Active, uint Panes);
public sealed record TmuxSessionInfo(string Id, string Name, bool Attached, IReadOnlyList<TmuxWindow> Windows);

public sealed record SkippedKey(uint Position, string? Fingerprint, string Reason);
