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

    /// <summary>
    /// Paints the one brush shared by the terminal canvas and the selected tab.
    /// </summary>
    public static void SetCanvas(Palette palette)
    {
        if (Application.Current.Resources["TerminalCanvasBrush"] is SolidColorBrush brush)
            brush.Color = Background(palette).Color;
    }
}
