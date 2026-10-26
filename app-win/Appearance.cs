using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Tether;

namespace TetherApp;

internal static class Appearance
{
    public static ElementTheme RequestedTheme => AppSettings.Current.Appearance switch
    {
        "dark" => ElementTheme.Dark,
        "light" => ElementTheme.Light,
        _ => ElementTheme.Default,
    };

    public static SolidColorBrush Background(Palette palette)
    {
        var color = palette.Background;
        return new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(
            color.AlphaByte, color.RedByte, color.GreenByte, color.BlueByte));
    }

    public static SolidColorBrush WorkspaceBackground(Palette palette, Brush? existing = null)
    {
        var background = palette.Background with { Alpha = (float)WindowEffects.Opacity };
        var color = Microsoft.UI.ColorHelper.FromArgb(background.AlphaByte, background.RedByte, background.GreenByte, background.BlueByte);
        if (existing is not SolidColorBrush brush) return new SolidColorBrush(color);
        if (brush.Color != color) brush.Color = color;
        return brush;
    }

    /// <summary>The canvas and selected tab expose the one native workspace tint.</summary>
    public static void SetCanvas(Palette palette)
    {
        if (Application.Current.Resources["TerminalCanvasBrush"] is SolidColorBrush brush)
            brush.Color = palette.Background.Alpha < 1 ? Microsoft.UI.Colors.Transparent : Background(palette).Color;
    }
}
