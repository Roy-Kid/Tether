// The session loop, the same shape `SessionModel.swift` runs on Apple.
//
//     set_palette → frame → while await_change { frame; redraw }
//     → final frame + ending
//
// Keys, not bytes. Scroll chords are stolen before Send. Resize skips 0 and
// unchanged. One palette chooser feeds both the draw path and the session.

using System.Threading;
using Microsoft.UI.Xaml;
using Tether;

namespace TetherApp;

public sealed class SessionModel : IAsyncDisposable
{
    private TerminalSession? _session;
    private readonly object _gate = new();
    private readonly object _dialGate = new();
    private Palette _palette = Palette.Dark;
    private ScreenFrame? _frame;
    private ushort _columns = 80;
    private ushort _rows = 24;
    private RemoteBar _bar = RemoteBar.Idle();
    private int _attempt;
    private CancellationTokenSource? _dial;
    private Timer? _clock;
    private volatile bool _awaitingPerson;
    private volatile bool _userCancelled;
    private volatile bool _timedOut;
    private int _timeoutSeconds = RemoteLink.DefaultTimeoutSeconds;

    /// <summary>Raised when a new frame is ready to draw.</summary>
    public event Action<ScreenFrame>? FrameChanged;

    public Palette Palette => _palette;
    public bool IsLive => Status == "Connected";
    public int Generation { get; private set; }
    public bool IsRemote { get; private set; }

    /// <summary>The host this tab dialed. Reconnect uses this object, not a fresh lookup.</summary>
    public HostEntry? RemoteHost { get; private set; }

    /// <summary>What the host bar draws for the dial in flight.</summary>
    public RemoteBar Bar => _bar;

    /// <summary>A remote host is remembered and the bar is offering another dial.</summary>
    public bool CanReconnect => RemoteHost is not null && _bar.OffersReconnect;

    /// <summary>The handshake's cancel signal. Auth dialogs close when it fires.</summary>
    public CancellationToken DialToken
    {
        get { lock (_dialGate) return _dial?.Token ?? CancellationToken.None; }
    }

    /// <summary>The local profile is WSL: paths the shell understands are Linux paths.</summary>
    public bool IsWsl =>
        Path.GetFileNameWithoutExtension(LocalProfile).Equals("wsl", StringComparison.OrdinalIgnoreCase);
    public string LocalProfile { get; private set; } = "pwsh";
    public event Action? SessionChanged;
    public string? WorkingDirectory => _session?.WorkingDirectory();
    public Task<RemoteFiles> OpenFilesAsync(CancellationToken token) =>
        _session?.OpenFilesAsync(token) ?? throw new InvalidOperationException("No live session.");

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

    /// <summary>Remembers <paramref name="host"/> so a later reconnect dials the same configuration.</summary>
    public void Keep(HostEntry host) => RemoteHost = host;

    /// <summary>
    /// Attaches to an OpenSSH master for <paramref name="alias"/>. The master
    /// already authenticated, so this does not ask for a verification code.
    /// </summary>
    public async Task<bool> AttachMasterAsync(string alias)
    {
        var attempt = _attempt;
        var token = DialToken;
        try
        {
            var session = await TerminalSession.ConnectOverSshAsync(
                alias, _columns, _rows, cancellationToken: token).ConfigureAwait(true);
            if (attempt != _attempt)
            {
                session.Dispose();
                return false;
            }
            StopClock();
            IsRemote = true;
            Adopt(session);
            return true;
        }
        catch (Exception ex)
        {
            if (attempt != _attempt) return false;
            StopClock();
            var bar = ex is TetherException.Cancelled
                ? RemoteBar.AfterStop(_userCancelled, _timedOut)
                : RemoteBar.Failed();
            Apply(bar, bar.Status == "Cancelled" ? null : ex.Message);
            return false;
        }
    }

    /// <summary>
    /// Starts the connecting state and the deadline. One dial at a time: a
    /// new attempt cancels the previous one. The clock pauses while a person
    /// is answering, and starts again afterwards — typing a password is not
    /// a timed-out route.
    /// </summary>
    public void Begin(HostEntry host)
    {
        RemoteHost = host;
        _timeoutSeconds = RemoteLink.TimeoutSeconds(host.ConnectTimeoutSeconds);
        ReplaceDial();
        Apply(RemoteBar.Connecting(), null);
    }

    /// <summary>The host bar's Cancel. Distinct from the deadline firing.</summary>
    public void CancelDial()
    {
        lock (_dialGate)
        {
            _userCancelled = true;
            _timedOut = false;
            _dial?.Cancel();
        }
    }

    /// <summary>The handshake is waiting on a trust decision or a prompt.</summary>
    public void NoteAsking()
    {
        lock (_dialGate)
        {
            _awaitingPerson = true;
            _clock?.Dispose();
            _clock = null;
        }
        if (_bar.Phase is RemotePhase.Connecting or RemotePhase.Authenticating)
            Apply(RemoteBar.Authenticating(), null);
    }

    /// <summary>The person answered. The rest of the handshake is on the clock again.</summary>
    public void NoteDialing()
    {
        CancellationTokenSource? dial;
        lock (_dialGate)
        {
            _awaitingPerson = false;
            dial = _dial;
            if (dial is { IsCancellationRequested: false }) StartClock(dial);
        }
        if (_bar.Phase == RemotePhase.Authenticating)
            Apply(RemoteBar.Connecting(), null);
    }

    /// <summary>
    /// Connects over SSH. Trust and prompts surface as dialogs (spec §18:
    /// strict host verification, no trust-all). Call <see cref="Begin"/> first
    /// so the bar can cancel this attempt.
    /// </summary>
    public async Task<bool> ConnectAsync(
        XamlRoot root,
        Destination destination,
        Secret[] secrets,
        IReadOnlyList<Tether.Jump>? jumps = null,
        CancellationToken cancellationToken = default)
    {
        var attempt = _attempt;
        var token = DialToken;
        if (!token.CanBeCanceled) token = cancellationToken;
        try
        {
            var session = await TerminalSession.ConnectAsync(
                destination,
                new TrustDialog(root, this),
                secrets,
                jumps ?? Array.Empty<Tether.Jump>(),
                token).ConfigureAwait(true);

            if (attempt != _attempt)
            {
                session.Dispose();
                return false;
            }
            StopClock();
            IsRemote = true;
            Adopt(session);
            return true;
        }
        catch (Exception ex)
        {
            if (attempt != _attempt) return false;
            StopClock();
            var bar = ex is TetherException.Cancelled
                ? RemoteBar.AfterStop(_userCancelled, _timedOut)
                : _userCancelled || _timedOut
                    ? RemoteBar.AfterStop(_userCancelled, _timedOut)
                    : RemoteBar.Failed();
            var detail = bar.Status switch
            {
                "Timed out" => $"Stopped after {_timeoutSeconds}s",
                "Cancelled" => null,
                _ => ex.Message,
            };
            Apply(bar, detail);
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
            Apply(RemoteBar.Idle() with { Status = "Local shell unavailable" }, null);
            return false;
        }
        try
        {
            var session = await TerminalSession.OpenLocalAsync(
                shell: AppSettings.ResolveShellProgram(shell ?? AppSettings.Current.Shell)).ConfigureAwait(true);
            IsRemote = false;
            LocalProfile = shell ?? AppSettings.Current.Shell;
            Adopt(session);
            return true;
        }
        catch (Exception ex)
        {
            // A shell that will not start is the whole window failing. Say
            // so in the status bar rather than leaving a silent black page.
            Apply(RemoteBar.ShellFailed(), ex.Message);
            return false;
        }
    }

    /// <summary>What the host bar shows. Silence is the connected state.</summary>
    public string Status => _bar.Status;

    /// <summary>Why the last thing failed, when it did. The bar shows a short label; this is the tooltip.</summary>
    public string? LastError { get; private set; }

    /// <summary>A refusal before a handshake, such as a <c>ProxyJump</c> that cycles.</summary>
    public void Fail(string message)
    {
        Disarm();
        Apply(RemoteBar.Failed(), message);
    }

    /// <summary>
    /// Takes a live session and starts drawing it. One place decides which
    /// palette (Decision 0011): the surface draws with this and the session
    /// tells the far side about it — before the first byte, because a
    /// program can query `OSC 11` in its first breath.
    /// </summary>
    private void Adopt(TerminalSession session)
    {
        session.SetPalette(_palette.RemoteForm());
        // The control may already have measured its grid for the previous
        // shell. A new SSH session still starts at its default 80 x 24.
        session.Resize(_columns, _rows);
        var previous = _session;
        _session = session;
        Generation++;
        previous?.Dispose();
        Apply(RemoteBar.Connected(), null);
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
                if (!ReferenceEquals(_session, session)) return;
                Publish(session.Frame());
            }
            // The final frame is announced before the ending; draw it.
            if (!ReferenceEquals(_session, session)) return;
            // A dial replaced the bar but not yet the session. This ending
            // belongs to the shell that is about to be dropped.
            if (_bar.ShowsCancel) return;
            Publish(session.Frame());
            var ending = session.Ending();
            if (IsRemote && RemoteHost is not null && ending is SessionEnding.Lost lost)
                Apply(RemoteBar.Lost(), string.IsNullOrEmpty(lost.Cause) ? null : lost.Cause);
            else if (IsRemote && RemoteHost is not null)
                Apply(RemoteBar.Ended(SessionStatus.Describe(ending)), null);
            else
                Apply(RemoteBar.Ended(SessionStatus.Describe(ending)) with { OffersReconnect = false }, null);
        }
        catch (TetherException ex)
        {
            if (!ReferenceEquals(_session, session) || _bar.ShowsCancel) return;
            if (IsRemote && RemoteHost is not null)
                Apply(RemoteBar.Lost(), ex.Message);
            else
                Apply(RemoteBar.Lost() with { OffersReconnect = false }, ex.Message);
        }
        catch (Exception) when (!ReferenceEquals(_session, session)) { }
    }

    /// <summary>Switches the theme. Re-sets the palette mid-session (0011).</summary>
    public void SetPalette(Palette palette)
    {
        _palette = palette;
        _session?.SetPalette(palette.RemoteForm());
        if (CurrentFrame is { } frame) FrameChanged?.Invoke(frame);
    }

    /// <summary>Sends a key. Encoding is the engine's, against remote modes.</summary>
    public void Send(TerminalInput input)
    {
        if (!IsLive) return;
        try { _session?.Send(input); }
        catch (TetherException.SessionEnded) { }
    }

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

    public void Wheel(int lines, ushort row, ushort column, bool local)
    {
        if (_session is null) return;
        _session.Wheel(lines, row, column, local);
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
        Disarm();
        var previous = _session;
        _session = null;
        Generation++;
        previous?.Dispose();
        Apply(RemoteBar.Closed(), null);
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

    private void Apply(RemoteBar bar, string? error)
    {
        _bar = bar;
        LastError = error;
        SessionChanged?.Invoke();
    }

    private void ReplaceDial()
    {
        lock (_dialGate)
        {
            _attempt++;
            _awaitingPerson = false;
            _userCancelled = false;
            _timedOut = false;
            _clock?.Dispose();
            _clock = null;
            _dial?.Cancel();
            _dial?.Dispose();
            var dial = new CancellationTokenSource();
            _dial = dial;
            StartClock(dial);
        }
    }

    private void StartClock(CancellationTokenSource dial)
    {
        _clock?.Dispose();
        var seconds = _timeoutSeconds;
        _clock = new Timer(_ =>
        {
            if (_awaitingPerson) return;
            lock (_dialGate)
            {
                if (_awaitingPerson || !ReferenceEquals(_dial, dial)) return;
                _timedOut = true;
                _userCancelled = false;
            }
            try { dial.Cancel(); } catch (ObjectDisposedException) { }
        }, null, TimeSpan.FromSeconds(seconds), Timeout.InfiniteTimeSpan);
    }

    private void StopClock()
    {
        lock (_dialGate)
        {
            _clock?.Dispose();
            _clock = null;
            _awaitingPerson = false;
        }
    }

    /// <summary>Drops the in-flight dial so a late completion cannot paint over a newer one.</summary>
    private void Disarm()
    {
        lock (_dialGate)
        {
            _attempt++;
            _awaitingPerson = false;
            _clock?.Dispose();
            _clock = null;
            _dial?.Cancel();
            _dial?.Dispose();
            _dial = null;
        }
    }

    /// <summary>
    /// Host-key trust against <c>~/.ssh/known_hosts</c> (spec §18: strict
    /// host verification, no trust-all). A key already recorded is trusted
    /// without asking; a new or changed key reaches the person.
    /// </summary>
    private sealed class TrustDialog(XamlRoot root, SessionModel model) : IHostTrust
    {
        private readonly Microsoft.UI.Dispatching.DispatcherQueue _queue = root.Content.DispatcherQueue;
        private readonly KnownHosts _known = new();

        public async Task<bool> TrustsAsync(HostIdentity host, CancellationToken cancellationToken)
        {
            var question = _known.Question(host);
            if (question is null) return true;

            model.NoteAsking();
            try
            {
                // A revoked key is never remembered and never accepted, even if
                // the person presses every button on the notice.
                var ok = await Alerts.TrustAsync(_queue, host, question, model.DialToken).ConfigureAwait(true);
                if (ok && question is not TrustQuestion.Revoked) _known.Remember(host);
                return ok;
            }
            finally
            {
                model.NoteDialing();
            }
        }

        public Task<bool> TrustsAsync(HostIdentity host)
            => TrustsAsync(host, CancellationToken.None);
    }

    /// <summary>Keyboard-interactive as a dialog. Echo is honoured (spec §10).</summary>
    public sealed class PromptDialog(XamlRoot root, SessionModel? model = null) : IAuthPrompter
    {
        private readonly Microsoft.UI.Dispatching.DispatcherQueue _queue = root.Content.DispatcherQueue;

        public async Task<IReadOnlyList<string>> AnswerAsync(
            string instruction, IReadOnlyList<AuthPrompt> prompts, CancellationToken cancellationToken)
        {
            model?.NoteAsking();
            try
            {
                var token = model?.DialToken ?? cancellationToken;
                return await Alerts.PromptsAsync(_queue, instruction, prompts, token).ConfigureAwait(true);
            }
            finally
            {
                model?.NoteDialing();
            }
        }

        public Task<IReadOnlyList<string>> AnswerAsync(
            string instruction, IReadOnlyList<AuthPrompt> prompts)
            => AnswerAsync(instruction, prompts, CancellationToken.None);
    }
}
