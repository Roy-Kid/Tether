using Tether;

namespace TetherApp;

public static class SessionStatus
{
    public static string Describe(SessionEnding? ending) => ending switch
    {
        SessionEnding.Exited exit => $"Exited ({exit.Status})",
        SessionEnding.Lost => "Connection lost",
        SessionEnding.Closed => "Closed",
        _ => "Ended",
    };
}
