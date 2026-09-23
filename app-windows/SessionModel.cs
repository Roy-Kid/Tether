// The session loop, the same shape `SessionModel.swift` runs on Apple.
//
//     set_palette → frame → while await_change { frame; redraw }
//     → final frame + ending
//
// Keys, not bytes. Scroll chords are stolen before Send. Resize skips 0 and
// unchanged. One palette chooser feeds both the draw path and the session.

using Microsoft.UI.Xaml;
using Tether;

namespace TetherApp;

public sealed class SessionModel : IAsyncDisposable
{
    private TerminalSession? _session;
    private readonly object _gate = new();
    private Palette _palette = Palette.Dark;
    private ScreenFrame? _frame;
    private ushort _columns = 80;
    private ushort _rows = 24;

    /// <summary>Raised when a new frame is ready to draw.</summary>
    public event Action<ScreenFrame>? FrameChanged;

    public Palette Palette => _palette;

    public ScreenFrame? CurrentFrame
    {
        get { lock (_gate) return _frame; }
    }

    /// <summary>
    /// Whether this platform lets an application start a shell. The host
    /// leaves the feature out of its interface rather than offering one that
    /// always refuses.
    /// </summary>
    public bool LocalShellAvailable => TerminalSession.LocalShellAvailable;

    /// <summary>
    /// Connects over SSH. Trust and prompts surface as dialogs (spec §18:
    /// strict host verification, no trust-all).
    /// </summary>
    public async Task<bool> ConnectAsync(
        XamlRoot root,
        Destination destination,
        Secret[] secrets,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var session = await TerminalSession.ConnectAsync(
                destination,
                new TrustDialog(root),
                secrets,
                cancellationToken).ConfigureAwait(true);

            Adopt(session);
            Status = "Connected";
            return true;
        }
        catch (Exception ex)
        {
            Status = "Disconnected";
            LastError = ex.Message;
            return false;
        }
    }

    /// <summary>
    /// Opens a shell on this machine. The default when a window opens: a
    /// terminal with nothing in it is a missing feature, and every other
    /// terminal on this machine starts here too.
    /// </summary>
    public async Task<bool> OpenLocalAsync(string? shell = null, CancellationToken cancellationToken = default)
    {
        if (!TerminalSession.LocalShellAvailable)
        {
            Status = "Local shell unavailable";
            return false;
        }
        try
        {
            var session = await TerminalSession.OpenLocalAsync(
                shell: shell).ConfigureAwait(true);
            Adopt(session);
            Status = "Connected";
            return true;
        }
        catch (Exception ex)
        {
            // A shell that will not start is the whole window failing. Say
            // so in the status bar rather than leaving a silent black page.
            Status = "Shell failed";
            LastError = ex.Message;
            return false;
        }
    }

    /// <summary>What the host bar shows. Silence is the connected state.</summary>
    public string Status { get; private set; } = "Not connected";

    /// <summary>Why the last thing failed, when it did.</summary>
    public string? LastError { get; private set; }

    /// <summary>
    /// Takes a live session and starts drawing it. One place decides which
    /// palette (Decision 0011): the surface draws with this and the session
    /// tells the far side about it — before the first byte, because a
    /// program can query `OSC 11` in its first breath.
    /// </summary>
    private void Adopt(TerminalSession session)
    {
        session.SetPalette(_palette.RemoteForm());
        _session = session;
        Publish(session.Frame());
        _ = PumpAsync(session);
    }

    /// <summary>The repaint loop. Costs nothing while the screen is still.</summary>
    private async Task PumpAsync(TerminalSession session)
    {
        try
        {
            while (await session.AwaitChangeAsync().ConfigureAwait(false))
            {
                Publish(session.Frame());
            }
            // The final frame is announced before the ending; draw it.
            Publish(session.Frame());
            _ = session.Ending();
        }
        catch (TetherException)
        {
            // A disconnected session is a row that leaves, not a crash
            // (law: display only).
        }
    }

    /// <summary>Switches the theme. Re-sets the palette mid-session (0011).</summary>
    public void SetPalette(Palette palette)
    {
        _palette = palette;
        _session?.SetPalette(palette.RemoteForm());
        if (CurrentFrame is { } frame) FrameChanged?.Invoke(frame);
    }

    /// <summary>Sends a key. Encoding is the engine's, against remote modes.</summary>
    public void Send(TerminalInput input) => _session?.Send(input);

    /// <summary>What the text at a cell names, if anything (Decisions/0015).</summary>
    public TerminalLink? LinkAt(ushort row, ushort column) => _session?.LinkAt(row, column);

    /// <summary>
    /// Moves the scrollback, then pulls a frame immediately so scrollback
    /// does not lag waiting for the next change.
    /// </summary>
    public void Scroll(ScrollTo to)
    {
        if (_session is null) return;
        _session.Scroll(to);
        Publish(_session.Frame());
    }

    /// <summary>Tells the engine the window changed size. Skips 0 and unchanged.</summary>
    public void Resize(ushort columns, ushort rows)
    {
        if (columns == 0 || rows == 0) return;
        if (columns == _columns && rows == _rows) return;
        _columns = columns;
        _rows = rows;
        _session?.Resize(columns, rows);
    }

    public void Close()
    {
        _session?.Close();
        _session = null;
    }

    public ValueTask DisposeAsync()
    {
        Close();
        return ValueTask.CompletedTask;
    }

    private void Publish(ScreenFrame frame)
    {
        lock (_gate) _frame = frame;
        FrameChanged?.Invoke(frame);
    }

    /// <summary>
    /// Host-key trust against <c>~/.ssh/known_hosts</c> (spec §18: strict
    /// host verification, no trust-all). A key already recorded is trusted
    /// without asking; a new or changed key reaches the person.
    /// </summary>
    private sealed class TrustDialog(XamlRoot root) : IHostTrust
    {
        private readonly KnownHosts _known = new();

        public async Task<bool> TrustsAsync(HostIdentity host, CancellationToken cancellationToken)
        {
            var question = _known.Question(host);
            if (question is null) return true;

            // A revoked key is never remembered and never accepted, even if
            // the person presses every button on the notice.
            var ok = await Alerts.TrustAsync(root, host, question).ConfigureAwait(true);
            if (ok && question is not TrustQuestion.Revoked) _known.Remember(host);
            return ok;
        }

        public Task<bool> TrustsAsync(HostIdentity host)
            => TrustsAsync(host, CancellationToken.None);
    }

    /// <summary>Keyboard-interactive as a dialog. Echo is honoured (spec §10).</summary>
    public sealed class PromptDialog(XamlRoot root) : IAuthPrompter
    {
        public Task<IReadOnlyList<string>> AnswerAsync(
            string instruction, IReadOnlyList<AuthPrompt> prompts, CancellationToken cancellationToken)
            => Alerts.PromptsAsync(root, instruction, prompts);

        public Task<IReadOnlyList<string>> AnswerAsync(
            string instruction, IReadOnlyList<AuthPrompt> prompts)
            => AnswerAsync(instruction, prompts, CancellationToken.None);
    }
}
