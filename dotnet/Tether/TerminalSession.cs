// A live terminal session, in the shape a UI author calls.
//
// The canonical loop, the same one `SessionModel.swift` runs on Apple:
//
//     await using var session = await TerminalSession.ConnectAsync(...);
//     session.SetPalette(palette);            // before the first byte
//     var frame = session.Frame();
//     while (await session.AwaitChangeAsync())
//     {
//         frame = session.Frame();
//         redraw(frame);
//     }
//     var ending = session.Ending();
//
// Keys, not bytes. Encoding is the engine's, against the modes the *remote*
// program set (spec §12).
//
// `Gen` is uniffi-bindgen-cs output. It stays `internal`, and the alias is
// how we keep generated names from colliding with the public contract
// (Decisions/0004: generated symbols must not leak).

using Gen = global::uniffi.tether_ffi;

namespace Tether;

/// <summary>A live terminal session.</summary>
public sealed class TerminalSession : IAsyncDisposable, IDisposable
{
    private readonly Gen.Session _inner;
    private bool _disposed;

    private TerminalSession(Gen.Session inner) => _inner = inner;

    /// <summary>Connects, authenticates and opens a shell.</summary>
    public static async Task<TerminalSession> ConnectAsync(
        Destination destination,
        IHostTrust trust,
        IReadOnlyList<Secret> secrets,
        IReadOnlyList<Jump>? jumps = null,
        CancellationToken cancellationToken = default)
    {
        using var cancellation = new CancellationTokenAdapter(cancellationToken);
        try
        {
            var inner = await Gen.TetherFfiMethods.ConnectCancellable(
                Lower(destination),
                new HostTrustAdapter(trust),
                secrets.Select(Lower).ToArray(),
                (jumps ?? Array.Empty<Jump>()).Select(Lower).ToArray(),
                cancellation.Ffi).ConfigureAwait(false);
            return new TerminalSession(inner);
        }
        catch (Gen.TetherException ex) { throw LiftError(ex); }
    }

    // Generated exception messages stringify arrays as "System.String[]".
    // Preserve the variant and its data at the public SDK boundary.
    private static TetherException LiftError(Gen.TetherException error) => error switch
    {
        Gen.TetherException.Cancelled => new TetherException.Cancelled(),
        Gen.TetherException.TimedOut e => new TetherException.TimedOut(e.millis),
        Gen.TetherException.Unreachable e => new TetherException.Unreachable(e.endpoint, e.cause),
        Gen.TetherException.HostRejected e => new TetherException.HostRejected(e.endpoint),
        Gen.TetherException.AuthenticationFailed e => new TetherException.AuthenticationFailed(e.remaining, e.skipped.Select(k => new SkippedKey(k.Position, k.Fingerprint, k.Problem switch
        {
            Gen.KeyProblem.Unreadable p => "Unreadable key: " + p.Cause,
            Gen.KeyProblem.Unsupported p => "Unsupported key: " + p.What,
            Gen.KeyProblem.Locked => "Key needs a passphrase",
            Gen.KeyProblem.WrongPassphrase => "Incorrect key passphrase",
            _ => "Key could not be used",
        })).ToArray()),
        Gen.TetherException.MoreFactorsNeeded e => new TetherException.MoreFactorsNeeded(e.remaining),
        Gen.TetherException.NothingToOffer => new TetherException.NothingToOffer(),
        Gen.TetherException.ShellRefused e => new TetherException.ShellRefused(e.cause),
        Gen.TetherException.Unsupported e => new TetherException.Unsupported(e.what),
        Gen.TetherException.Disconnected e => new TetherException.Disconnected(e.cause),
        Gen.TetherException.SessionEnded => new TetherException.SessionEnded(),
        Gen.TetherException.Protocol e => new TetherException.Protocol(e.cause),
        _ => new TetherException.Protocol(error.Message),
    };

    /// <summary>
    /// Opens a shell on this machine. <paramref name="shell"/> names the
    /// program — <c>pwsh</c>, <c>powershell</c>, <c>cmd</c> — and
    /// <c>null</c> is the platform default (a settings surface is what
    /// fills this in).
    /// </summary>
    public static async Task<TerminalSession> OpenLocalAsync(
        string? directory = null,
        string term = "xterm-256color",
        ushort columns = 80,
        ushort rows = 24,
        uint scrollbackLines = 10_000,
        string? shell = null,
        SessionHistory? history = null)
    {
        var inner = await Gen.TetherFfiMethods.OpenLocal(new Gen.LocalShell(
            directory, term, columns, rows, scrollbackLines, shell, history?.Inner)).ConfigureAwait(false);
        return new TerminalSession(inner);
    }

    /// <summary>
    /// Whether this platform lets an application start a shell. A question, so
    /// a consumer can leave the feature out of its interface rather than offer
    /// one that always refuses.
    /// </summary>
    public static bool LocalShellAvailable => Gen.TetherFfiMethods.LocalShellAvailable();

    /// <summary>
    /// Whether an OpenSSH multiplexing master is already running for
    /// <paramref name="alias"/>. The alias is the config stanza name, which
    /// is what the ControlPath was keyed on.
    /// </summary>
    public static Task<bool> SshMasterRunningAsync(string alias) =>
        Gen.TetherFfiMethods.SshMasterRunning(alias);

    /// <summary>
    /// Opens a shell on an existing OpenSSH master. No credential is offered:
    /// the handshake was spent when the master was created.
    /// </summary>
    public static async Task<TerminalSession> ConnectOverSshAsync(
        string alias,
        ushort columns = 80,
        ushort rows = 24,
        uint scrollbackLines = 10_000,
        CancellationToken cancellationToken = default,
        SessionHistory? history = null)
    {
        using var cancellation = new CancellationTokenAdapter(cancellationToken);
        var shell = new Gen.LocalShell(null, "xterm-256color", columns, rows, scrollbackLines, null, history?.Inner);
        try
        {
            var inner = await Gen.TetherFfiMethods.ConnectOverSshClientCancellable(
                alias, shell, cancellation.Ffi).ConfigureAwait(false);
            return new TerminalSession(inner);
        }
        catch (Gen.TetherException ex) { throw LiftError(ex); }
    }

    /// <summary>Everything needed to draw the screen once.</summary>
    public ScreenFrame Frame() => Lift(_inner.Frame());

    /// <summary>
    /// Waits until the screen changed, returning <c>false</c> once the session
    /// has ended and never will again. Costs nothing while the screen is
    /// still, and wakes on the first byte.
    /// </summary>
    public Task<bool> AwaitChangeAsync() => _inner.AwaitChange();

    /// <summary>
    /// Sends something the person did. A key, not bytes — encoding happens on
    /// the Rust side against the remote program's modes.
    /// </summary>
    public void Send(TerminalInput input) => _inner.Send(Lower(input));

    /// <summary>Tells both the engine and the far side that the window changed size.</summary>
    public void Resize(ushort columns, ushort rows) => _inner.Resize(columns, rows);

    /// <summary>Moves the viewport over the scrollback. Clamped at both ends.</summary>
    public void Scroll(ScrollTo to) => _inner.Scroll(Lower(to));

    public void Wheel(int lines, ushort row, ushort column, bool local = false) =>
        _inner.Wheel(lines, row, column, local);

    /// <summary>
    /// Tells the engine what this consumer draws with, so that a program
    /// asking for a colour is answered. Settable at any time.
    /// </summary>
    public void SetPalette(TerminalPalette? palette) =>
        _inner.SetPalette(palette is null ? null : Lower(palette));

    /// <summary><c>null</c> while the session is still running.</summary>
    public SessionEnding? Ending() => Lift(_inner.Ending());

    /// <summary>The directory the shell last reported, if it reports one.</summary>
    public string? WorkingDirectory() => _inner.WorkingDirectory();

    /// <summary>Opens SFTP on this session's authenticated connection.</summary>
    public async Task<RemoteFiles> OpenFilesAsync(CancellationToken cancellationToken = default)
    {
        using var connection = _inner.Connection()
            ?? throw new InvalidOperationException("This session has no live connection.");
        using var cancellation = new CancellationTokenAdapter(cancellationToken);
        try { return new RemoteFiles(await connection.Files(cancellation.Ffi).ConfigureAwait(false)); }
        catch (Gen.TetherException.Cancelled) { throw new OperationCanceledException(cancellationToken); }
        catch (Gen.TetherException ex) { throw new IOException("Could not open SFTP: " + ex.Message, ex); }
    }

    /// <summary>
    /// What the text at a cell names, if anything, and where it is drawn.
    /// Asked when a person points, not every frame (Decisions/0015).
    /// </summary>
    public TerminalLink? LinkAt(ushort row, ushort column) => Lift(_inner.LinkAt(row, column));

    /// <summary>Ends the session. Idempotent.</summary>
    public void Close() => _inner.Close();

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _inner.Close();
        _inner.Dispose();
    }

    public ValueTask DisposeAsync()
    {
        Dispose();
        return ValueTask.CompletedTask;
    }

    // ---- lowering: public contract → generated types ----
    // A field map, not a rename of a dependency: the generated types stay
    // `internal` so a consumer cannot name them (Decisions/0004).

    private static Gen.Destination Lower(Destination d) =>
        new(d.Host, d.Port, d.User, d.Term, d.Columns, d.Rows, d.ScrollbackLines, d.History?.Inner);

    private static Gen.Jump Lower(Jump jump) =>
        new(jump.Host, jump.Port, jump.User, jump.Secrets.Select(Lower).ToArray());

    private static Gen.Secret Lower(Secret s) => s switch
    {
        Secret.Password p => new Gen.Secret.Password(p.Value),
        Secret.PrivateKey k => new Gen.Secret.PrivateKey(k.Pem, k.Passphrase, k.Unlock is null ? null : new PassphraseAdapter(k.Unlock)),
        Secret.Interactive i => new Gen.Secret.Interactive(new PrompterAdapter(i.Prompter)),
        _ => throw new ArgumentOutOfRangeException(nameof(s)),
    };

    private static Gen.TerminalPalette Lower(TerminalPalette p) =>
        new(Lower(p.Foreground), Lower(p.Background), Lower(p.Cursor), p.Ansi.Select(Lower).ToArray());

    private static Gen.ColorValue Lower(ColorValue c) => new(c.Red, c.Green, c.Blue);

    private static Gen.TerminalInput Lower(TerminalInput input) => input switch
    {
        TerminalInput.Key k => new Gen.TerminalInput.Key(Lower(k.Press), Lower(k.Modifiers)),
        TerminalInput.Paste p => new Gen.TerminalInput.Paste(p.Text),
        TerminalInput.Pointer p => new Gen.TerminalInput.Pointer((Gen.PointerButton)p.Button, (Gen.PointerPhase)p.Phase, p.Column, p.Row, Lower(p.Modifiers)),
        _ => throw new ArgumentOutOfRangeException(nameof(input)),
    };

    private static Gen.KeyModifiers Lower(KeyModifiers m) => new(m.Shift, m.Alt, m.Control);

    private static Gen.KeyPress Lower(KeyPress key) => key switch
    {
        KeyPress.Char c => new Gen.KeyPress.Char(c.Text),
        KeyPress.Enter => new Gen.KeyPress.Enter(),
        KeyPress.Tab => new Gen.KeyPress.Tab(),
        KeyPress.Backspace => new Gen.KeyPress.Backspace(),
        KeyPress.Escape => new Gen.KeyPress.Escape(),
        KeyPress.Delete => new Gen.KeyPress.Delete(),
        KeyPress.Insert => new Gen.KeyPress.Insert(),
        KeyPress.Up => new Gen.KeyPress.Up(),
        KeyPress.Down => new Gen.KeyPress.Down(),
        KeyPress.Left => new Gen.KeyPress.Left(),
        KeyPress.Right => new Gen.KeyPress.Right(),
        KeyPress.Home => new Gen.KeyPress.Home(),
        KeyPress.End => new Gen.KeyPress.End(),
        KeyPress.PageUp => new Gen.KeyPress.PageUp(),
        KeyPress.PageDown => new Gen.KeyPress.PageDown(),
        KeyPress.Function f => new Gen.KeyPress.Function(f.Number),
        _ => throw new ArgumentOutOfRangeException(nameof(key)),
    };

    private static Gen.ScrollTo Lower(ScrollTo to) => to.Kind switch
    {
        ScrollToKind.Lines => new Gen.ScrollTo.Lines(to.LineCount),
        ScrollToKind.PageUp => new Gen.ScrollTo.PageUp(),
        ScrollToKind.PageDown => new Gen.ScrollTo.PageDown(),
        ScrollToKind.Oldest => new Gen.ScrollTo.Oldest(),
        ScrollToKind.Live => new Gen.ScrollTo.Live(),
        _ => throw new ArgumentOutOfRangeException(nameof(to)),
    };

    // ---- lifting: generated types → public contract ----

    private static ScreenFrame Lift(Gen.ScreenFrame f) => new(
        f.Columns, f.Rows, f.CursorRow, f.CursorColumn,
        Lift(f.CursorShape), f.CursorVisible, f.AlternateScreen,
        f.ViewportOffset, f.HistoryLines, f.Title,
        f.Lines.Select(Lift).ToArray()) { Mouse = (MouseTracking)f.Mouse };

    private static ScreenRow Lift(Gen.ScreenRow r) =>
        new(r.Runs.Select(Lift).ToArray());

    private static StyledRun Lift(Gen.StyledRun r) =>
        new(r.Text, r.Columns, Lift(r.Style));

    private static RunStyle Lift(Gen.CellStyle s) => new(
        Lift(s.Foreground), Lift(s.Background),
        Lift(s.Underline), s.UnderlineColor is null ? null : Lift(s.UnderlineColor),
        s.Bold, s.Dim, s.Italic, s.Strikethrough, s.Inverse, s.Hidden);

    private static CellColor Lift(Gen.CellColor c) => c switch
    {
        Gen.CellColor.Named n => new CellColor.Named(Lift(n.Name)),
        Gen.CellColor.Indexed i => new CellColor.Indexed(i.Index),
        Gen.CellColor.Rgb rgb => new CellColor.Rgb(rgb.Red, rgb.Green, rgb.Blue),
        _ => throw new ArgumentOutOfRangeException(nameof(c)),
    };

    private static ColorName Lift(Gen.ColorName n) => n switch
    {
        Gen.ColorName.Black => ColorName.Black,
        Gen.ColorName.Red => ColorName.Red,
        Gen.ColorName.Green => ColorName.Green,
        Gen.ColorName.Yellow => ColorName.Yellow,
        Gen.ColorName.Blue => ColorName.Blue,
        Gen.ColorName.Magenta => ColorName.Magenta,
        Gen.ColorName.Cyan => ColorName.Cyan,
        Gen.ColorName.White => ColorName.White,
        Gen.ColorName.BrightBlack => ColorName.BrightBlack,
        Gen.ColorName.BrightRed => ColorName.BrightRed,
        Gen.ColorName.BrightGreen => ColorName.BrightGreen,
        Gen.ColorName.BrightYellow => ColorName.BrightYellow,
        Gen.ColorName.BrightBlue => ColorName.BrightBlue,
        Gen.ColorName.BrightMagenta => ColorName.BrightMagenta,
        Gen.ColorName.BrightCyan => ColorName.BrightCyan,
        Gen.ColorName.BrightWhite => ColorName.BrightWhite,
        Gen.ColorName.Foreground => ColorName.Foreground,
        Gen.ColorName.Background => ColorName.Background,
        Gen.ColorName.Cursor => ColorName.Cursor,
        _ => throw new ArgumentOutOfRangeException(nameof(n)),
    };

    private static UnderlineStyle Lift(Gen.UnderlineStyle u) => u switch
    {
        Gen.UnderlineStyle.None => UnderlineStyle.None,
        Gen.UnderlineStyle.Single => UnderlineStyle.Single,
        Gen.UnderlineStyle.Double => UnderlineStyle.Double,
        Gen.UnderlineStyle.Curly => UnderlineStyle.Curly,
        Gen.UnderlineStyle.Dotted => UnderlineStyle.Dotted,
        Gen.UnderlineStyle.Dashed => UnderlineStyle.Dashed,
        _ => throw new ArgumentOutOfRangeException(nameof(u)),
    };

    private static CaretShape Lift(Gen.CaretShape c) => c switch
    {
        Gen.CaretShape.Block => CaretShape.Block,
        Gen.CaretShape.Underline => CaretShape.Underline,
        Gen.CaretShape.Beam => CaretShape.Beam,
        Gen.CaretShape.Hidden => CaretShape.Hidden,
        _ => throw new ArgumentOutOfRangeException(nameof(c)),
    };

    private static SessionEnding? Lift(Gen.SessionEnding? e) => e switch
    {
        null => null,
        Gen.SessionEnding.Exited x => new SessionEnding.Exited(x.Status),
        Gen.SessionEnding.Closed => new SessionEnding.Closed(),
        Gen.SessionEnding.Lost l => new SessionEnding.Lost(l.Cause),
        _ => throw new ArgumentOutOfRangeException(nameof(e)),
    };

    private static TerminalLink? Lift(Gen.TerminalLink? link) => link is null
        ? null
        : new TerminalLink(
            link.Text,
            Lift(link.Kind),
            link.Spans.Select(s => new LinkSpan(s.Row, s.Start, s.End)).ToArray());

    private static LinkKind Lift(Gen.LinkKind kind) => kind switch
    {
        Gen.LinkKind.Hyperlink h => new LinkKind.Hyperlink(h.Uri),
        Gen.LinkKind.Url u => new LinkKind.Url(u.UrlValue),
        Gen.LinkKind.Path p => new LinkKind.Path(p.PathValue, (int?)p.Line, (int?)p.Column),
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    // ---- foreign-trait adapters ----

    private sealed class HostTrustAdapter(IHostTrust inner) : Gen.HostTrust
    {
        public Task<bool> Trusts(Gen.HostIdentity host) =>
            inner.TrustsAsync(new Tether.HostIdentity(host.Host, host.Port, host.Algorithm, host.Fingerprint, host.Encoded));
    }

    private sealed class PassphraseAdapter(IPassphrasePrompter inner) : Gen.PassphrasePrompter
    {
        public Task<string?> Passphrase(Gen.LockedKey key, uint attempt) =>
            inner.PassphraseAsync(new LockedKey(key.Fingerprint, key.Comment), attempt);
    }

    public string? CurrentDirectory => _inner.CurrentDirectory();
    public string? TerminalName => _inner.TerminalName();
    public uint? LocalProcessId => _inner.LocalProcessId();
    public void CheckpointHistory() => _inner.CheckpointHistory();
    public string? HistoryError => _inner.HistoryError();
    public string? TakeClipboard() => _inner.TakeClipboard();
    public async Task<string> ExecuteAsync(string command, CancellationToken token = default)
    {
        using var connection = _inner.Connection() ?? throw new IOException("No live connection.");
        using var cancellation = new CancellationTokenAdapter(token);
        var result = await connection.Execute(command, cancellation.Ffi).ConfigureAwait(false);
        if (result.Status != 0) throw new IOException(System.Text.Encoding.UTF8.GetString(result.Stderr));
        return System.Text.Encoding.UTF8.GetString(result.Stdout);
    }

    public async Task<IReadOnlyList<TmuxSessionInfo>> TmuxSessionsAsync(CancellationToken token = default)
    {
        using var connection = _inner.Connection() ?? throw new IOException("No live connection.");
        using var cancellation = new CancellationTokenAdapter(token);
        return (await connection.TmuxSessions(cancellation.Ffi).ConfigureAwait(false)).Select(s =>
            new TmuxSessionInfo(s.Id, s.Name, s.Attached, s.Windows.Select(w => new TmuxWindow(w.Id, w.Index, w.Name, w.Active, w.Panes)).ToArray())).ToArray();
    }
    public async Task<TmuxSessionInfo> CreateTmuxAsync(string name, string? directory, CancellationToken token = default)
    {
        using var connection = _inner.Connection() ?? throw new IOException("No live connection.");
        using var cancellation = new CancellationTokenAdapter(token);
        var s = await connection.CreateTmux(name, directory, cancellation.Ffi).ConfigureAwait(false);
        return new(s.Id, s.Name, s.Attached, []);
    }
    public async Task RenameTmuxAsync(string id, string name)
    {
        using var connection = _inner.Connection() ?? throw new IOException("No live connection.");
        await connection.RenameTmux(id, name).ConfigureAwait(false);
    }
    public async Task EndTmuxAsync(string id)
    {
        using var connection = _inner.Connection() ?? throw new IOException("No live connection.");
        await connection.EndTmux(id).ConfigureAwait(false);
    }
    public async Task<string?> TmuxSessionForClientAsync(string tty)
    {
        using var connection = _inner.Connection() ?? throw new IOException("No live connection.");
        return await connection.TmuxSessionForClient(tty).ConfigureAwait(false);
    }

    private sealed class PrompterAdapter(IAuthPrompter inner) : Gen.InteractivePrompter
    {
        public async Task<string[]> Answer(string instruction, Gen.AuthPrompt[] prompts)
        {
            var ours = prompts.Select(p => new Tether.AuthPrompt(p.Text, p.Echo)).ToArray();
            var answers = await inner.AnswerAsync(instruction, ours).ConfigureAwait(false);
            return answers.ToArray();
        }
    }

    /// <summary>
    /// UniFFI's own cancellation token. Wired to a .NET token so a cancelled
    /// <c>Task</c> reaches the Rust future (Decisions/0003: UniFFI's generated
    /// bindings poll a Rust future to completion and ignore
    /// <c>Task.IsCancelled</c>).
    /// </summary>
    private sealed class CancellationTokenAdapter : IDisposable
    {
        private readonly CancellationTokenRegistration _registration;
        private readonly Gen.CancellationToken _ffi = new();

        public CancellationTokenAdapter(CancellationToken token)
        {
            if (token.CanBeCanceled)
            {
                _registration = token.Register(() => _ffi.Cancel());
            }
        }

        public Gen.CancellationToken Ffi => _ffi;

        public void Dispose()
        {
            _registration.Dispose();
            _ffi.Dispose();
        }
    }
}
