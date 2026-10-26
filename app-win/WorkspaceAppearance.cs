namespace TetherApp;

/// <summary>Matches the macOS workspace contract: one native tint beneath clear terminal surfaces.</summary>
internal static class WorkspaceAppearance
{
    public const double DefaultOpacity = 0.6;
    public const double MinimumOpacity = 0.5;

    public static double Opacity(bool frosted, double stored, bool reduceTransparency, bool increasedContrast)
    {
        if (!frosted || reduceTransparency || increasedContrast) return 1;
        return double.IsFinite(stored) ? Math.Clamp(stored, MinimumOpacity, 1) : DefaultOpacity;
    }
}
