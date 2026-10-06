// What the host bar shows while a remote dial is in flight, and the host
// configuration a later reconnect dials with.
//
// The snapshot is the host as it was chosen. Reconnect does not invent a
// destination from the alias alone: user, port, key, jumps and the timeout
// travel with it.

namespace TetherApp;

public enum RemotePhase
{
    None,
    Connecting,
    Authenticating,
    Connected,
    Lost,
    Failed,
    Cancelled,
    Ended,
}

/// <summary>Which host-bar controls a phase offers. Flags, because a local shell failure is not a remote reconnect.</summary>
public readonly record struct RemoteBar(
    RemotePhase Phase,
    string Status,
    bool ShowsProgress,
    bool ShowsAuth,
    bool ShowsCancel,
    bool OffersReconnect)
{
    public static RemoteBar Idle() => new(RemotePhase.None, "Not connected", false, false, false, false);
    public static RemoteBar Connecting() => new(RemotePhase.Connecting, "Connecting", true, false, true, false);
    public static RemoteBar Authenticating() => new(RemotePhase.Authenticating, "Needs authentication", false, true, true, false);
    public static RemoteBar Connected() => new(RemotePhase.Connected, "Connected", false, false, false, false);
    public static RemoteBar Lost() => new(RemotePhase.Lost, "Connection lost", false, false, false, true);
    public static RemoteBar Failed() => new(RemotePhase.Failed, "Disconnected", false, false, false, true);
    public static RemoteBar TimedOut() => new(RemotePhase.Cancelled, "Timed out", false, false, false, true);
    public static RemoteBar Stopped() => new(RemotePhase.Cancelled, "Cancelled", false, false, false, true);
    public static RemoteBar Ended(string status) => new(RemotePhase.Ended, status, false, false, false, true);
    public static RemoteBar ShellFailed() => new(RemotePhase.Failed, "Shell failed", false, false, false, false);
    public static RemoteBar Closed() => new(RemotePhase.None, "Closed", false, false, false, false);

    /// <summary>
    /// A person pressing Cancel wins over the clock. A clock that fired is
    /// "Timed out". Anything else that stopped the handshake without an error
    /// string — declining a prompt — is "Cancelled".
    /// </summary>
    public static RemoteBar AfterStop(bool userCancelled, bool timedOut) =>
        userCancelled ? Stopped() : timedOut ? TimedOut() : Stopped();
}

/// <summary>Where a reconnect dials. Built from the host that was chosen, not from a title string.</summary>
public readonly record struct DialPlan(
    string Host,
    ushort Port,
    string User,
    string? IdentityFile,
    IReadOnlyList<Jump> Hops,
    int TimeoutSeconds);

public static class RemoteLink
{
    /// <summary>
    /// OpenSSH leaves <c>ConnectTimeout</c> unset and waits on the system TCP
    /// timeout. A route that never answers outlives anyone watching it, so
    /// the bar's Cancel has a deadline when the file does not name one.
    /// </summary>
    public const int DefaultTimeoutSeconds = 30;

    public static int TimeoutSeconds(int? configured)
    {
        if (configured is not > 0) return DefaultTimeoutSeconds;
        // A day is as long as the bar will wait. Longer values still parse; the clock has to fit in a TimeSpan.
        return Math.Min(configured.Value, 86_400);
    }

    public static DialPlan Plan(HostEntry host, string fallbackUser)
    {
        var user = host.User;
        if (string.IsNullOrEmpty(user)) user = fallbackUser;
        return new DialPlan(
            host.HostName,
            host.Port ?? 22,
            user ?? fallbackUser,
            host.IdentityFile,
            host.Route,
            TimeoutSeconds(host.ConnectTimeoutSeconds));
    }

    /// <summary>The same dial a reconnect will make. Identity, hops and timeout included.</summary>
    public static bool SamePlan(DialPlan left, DialPlan right) =>
        left.Host == right.Host
        && left.Port == right.Port
        && left.User == right.User
        && left.IdentityFile == right.IdentityFile
        && left.TimeoutSeconds == right.TimeoutSeconds
        && left.Hops.Count == right.Hops.Count
        && left.Hops.Zip(right.Hops).All(pair => pair.First == pair.Second);
}
