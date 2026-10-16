using Tether;

namespace TetherApp;

internal static class TerminalAppearance
{
    public static Palette Choose(bool dark) => AppSettings.Current.Terminal.ColorScheme == "classic"
        ? (dark ? Palette.Dark : Palette.Light)
        : (dark ? SoftDark : SoftLight);

    private static Rgba Color(uint rgb) => new(
        ((rgb >> 16) & 255) / 255f, ((rgb >> 8) & 255) / 255f, (rgb & 255) / 255f, 1f);

    private static Rgba[] Colors(params uint[] colors) => colors.Select(Color).ToArray();

    // ANSI slots keep their meaning; true-color output remains the program's.
    private static readonly Palette SoftDark = new(
        Color(0x171B22), Color(0xD8DEE9), Color(0x9DC7F2),
        Colors(0x353D4B, 0xE58C91, 0xA3C99C, 0xEBCB8B, 0x8DB4E2, 0xC5A0D8, 0x88C6CA, 0xCBD3DF),
        Colors(0x758298, 0xF0A5AA, 0xB9DBB3, 0xF5DAA2, 0xACCBEE, 0xDBBCE9, 0xA5DBDF, 0xEEF2F8));

    private static readonly Palette SoftLight = new(
        Color(0xF7F8FA), Color(0x283242), Color(0x356AA3),
        Colors(0x283242, 0xA83C48, 0x326C46, 0x805C19, 0x315FA3, 0x78509D, 0x246F78, 0x526074),
        Colors(0x69758A, 0xBA4854, 0x397A50, 0x89631B, 0x3B6BB4, 0x865BAB, 0x2C7D86, 0x526074));
}
