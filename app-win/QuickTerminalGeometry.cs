namespace TetherApp;

public readonly record struct QuickTerminalBounds(int X, int Y, int Width, int Height);

public static class QuickTerminalGeometry
{
    // Native monitor work-area coordinates: taskbar excluded, negative origins retained.
    public static QuickTerminalBounds TopHalf(QuickTerminalBounds workArea, int minimumHeight) =>
        workArea with { Height = Math.Min(workArea.Height, Math.Max(minimumHeight, workArea.Height / 2)) };
}
