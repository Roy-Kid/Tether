// Resolves the names the engine reports into colours this consumer draws.
//
// The engine deliberately reports `red`, not an RGB triple, because the
// consumer owns the palette (spec §12, Decision 0011). One place decides what
// red means; a light theme is a different instance of this class rather than
// a change anywhere else. The same instance feeds both the draw path and
// `TerminalSession.SetPalette`, so a screen drawn light while the far side was
// told "dark" cannot happen.

namespace Tether;

/// <summary>Sixteen ANSI slots plus the three the theme supplies.</summary>
public sealed record Palette(
    Rgba Background,
    Rgba Foreground,
    Rgba Cursor,
    IReadOnlyList<Rgba> Normal,
    IReadOnlyList<Rgba> Bright)
{
    /// <summary>A dark theme with the usual sixteen. Matches <c>TetherUI.Palette.dark</c>.</summary>
    public static Palette Dark { get; } = new(
        new Rgba(0.07f, 0.08f, 0.10f, 1f),
        new Rgba(0.87f, 0.88f, 0.90f, 1f),
        new Rgba(0.55f, 0.78f, 0.96f, 1f),
        new[]
        {
            new Rgba(0.16f, 0.17f, 0.20f, 1f),
            new Rgba(0.90f, 0.38f, 0.40f, 1f),
            new Rgba(0.47f, 0.76f, 0.45f, 1f),
            new Rgba(0.90f, 0.72f, 0.36f, 1f),
            new Rgba(0.40f, 0.62f, 0.90f, 1f),
            new Rgba(0.76f, 0.51f, 0.85f, 1f),
            new Rgba(0.36f, 0.75f, 0.77f, 1f),
            new Rgba(0.78f, 0.79f, 0.81f, 1f),
        },
        new[]
        {
            new Rgba(0.34f, 0.36f, 0.40f, 1f),
            new Rgba(0.96f, 0.50f, 0.51f, 1f),
            new Rgba(0.60f, 0.86f, 0.57f, 1f),
            new Rgba(0.96f, 0.82f, 0.48f, 1f),
            new Rgba(0.53f, 0.72f, 0.96f, 1f),
            new Rgba(0.85f, 0.63f, 0.93f, 1f),
            new Rgba(0.48f, 0.85f, 0.87f, 1f),
            new Rgba(0.94f, 0.95f, 0.96f, 1f),
        });

    public static Palette Light { get; } = new(
        new Rgba(0.985f, 0.985f, 0.99f, 1f),
        new Rgba(0.12f, 0.13f, 0.16f, 1f),
        new Rgba(0f, 0f, 1f, 1f),
        new[]
        {
            new Rgba(0f, 0f, 0f, 1f),
            new Rgba(0.7f, 0.12f, 0.17f, 1f),
            new Rgba(0.1f, 0.4f, 0.2f, 1f),
            new Rgba(0.55f, 0.35f, 0.05f, 1f),
            new Rgba(0f, 0f, 1f, 1f),
            new Rgba(0.5f, 0f, 0.5f, 1f),
            new Rgba(0f, 0.4f, 0.5f, 1f),
            new Rgba(0.5f, 0.5f, 0.5f, 1f),
        },
        new[]
        {
            new Rgba(0.5f, 0.5f, 0.5f, 1f),
            new Rgba(1f, 0f, 0f, 1f),
            new Rgba(0.1f, 0.5f, 0.25f, 1f),
            new Rgba(1f, 0.5f, 0f, 1f),
            new Rgba(0f, 0f, 1f, 1f),
            new Rgba(0.5f, 0f, 0.5f, 1f),
            new Rgba(0f, 0.5f, 0.5f, 1f),
            new Rgba(1f, 1f, 1f, 1f),
        });

    /// <summary>Which palette a setting and a system appearance add up to.</summary>
    /// <remarks>
    /// One place, because two would drift: the surface draws with this and the
    /// session tells the far side about it.
    /// </remarks>
    public static Palette Chosen(string setting, bool systemIsDark) =>
        setting == "dark" || (setting == "system" && systemIsDark) ? Dark : Light;

    public Rgba Resolve(CellColor color) => color switch
    {
        CellColor.Named n => Resolve(n.Name),
        CellColor.Indexed i => Resolve(i.Index),
        CellColor.Rgb rgb => new Rgba(rgb.Red / 255f, rgb.Green / 255f, rgb.Blue / 255f, 1f),
        _ => throw new ArgumentOutOfRangeException(nameof(color)),
    };

    public Rgba Resolve(ColorName name) => name switch
    {
        ColorName.Black => Normal[0],
        ColorName.Red => Normal[1],
        ColorName.Green => Normal[2],
        ColorName.Yellow => Normal[3],
        ColorName.Blue => Normal[4],
        ColorName.Magenta => Normal[5],
        ColorName.Cyan => Normal[6],
        ColorName.White => Normal[7],
        ColorName.BrightBlack => Bright[0],
        ColorName.BrightRed => Bright[1],
        ColorName.BrightGreen => Bright[2],
        ColorName.BrightYellow => Bright[3],
        ColorName.BrightBlue => Bright[4],
        ColorName.BrightMagenta => Bright[5],
        ColorName.BrightCyan => Bright[6],
        ColorName.BrightWhite => Bright[7],
        ColorName.Foreground => Foreground,
        ColorName.Background => Background,
        ColorName.Cursor => Cursor,
        _ => throw new ArgumentOutOfRangeException(nameof(name)),
    };

    /// <summary>
    /// The standard 256-colour layout: sixteen named, then a 6×6×6 cube, then
    /// twenty-four greys. Computed rather than tabulated — the levels are not
    /// evenly spaced, which is why the first step is 0 and the rest are 55 apart.
    /// </summary>
    public Rgba Resolve(byte index) => index switch
    {
        < 8 => Normal[index],
        < 16 => Bright[index - 8],
        < 232 => Cube(index - 16),
        _ => Grey(index - 232),
    };

    private static Rgba Cube(int value)
    {
        static float Level(int step) => step == 0 ? 0f : (55 + step * 40) / 255f;
        return new Rgba(Level(value / 36), Level(value / 6 % 6), Level(value % 6), 1f);
    }

    private static Rgba Grey(int step)
    {
        var grey = (8 + step * 10) / 255f;
        return new Rgba(grey, grey, grey, 1f);
    }

    /// <summary>This palette in the form the far side is told it.</summary>
    /// <remarks>
    /// Only for answering colour queries. What the engine reports is still
    /// names; this is what those names look like here (spec §12).
    /// </remarks>
    public TerminalPalette RemoteForm()
    {
        var ansi = Normal.Concat(Bright).Select(ToColorValue).ToArray();
        return TerminalPalette.FromRgba(
            ToTuple(Foreground), ToTuple(Background), ToTuple(Cursor),
            ansi.Select(c => (c.Red, c.Green, c.Blue)).ToArray());
    }

    private static (byte, byte, byte) ToTuple(Rgba c) =>
        (c.RedByte, c.GreenByte, c.BlueByte);

    private static ColorValue ToColorValue(Rgba c) =>
        new(c.RedByte, c.GreenByte, c.BlueByte);
}

/// <summary>A straight colour, alpha included.</summary>
public readonly record struct Rgba(float Red, float Green, float Blue, float Alpha)
{
    public byte RedByte => ToByte(Red);
    public byte GreenByte => ToByte(Green);
    public byte BlueByte => ToByte(Blue);
    public byte AlphaByte => ToByte(Alpha);

    public Rgba WithAlpha(float alpha) => this with { Alpha = alpha };

    private static byte ToByte(float value) =>
        (byte)Math.Round(Math.Clamp(value, 0f, 1f) * 255f);
}
