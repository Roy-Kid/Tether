// The GPU surface, in the shape a UI author calls.
//
// Toolkit-free at the boundary (spec §8): a window handle and a `ScreenFrame`.
// `wgpu`, `glyphon` and `cosmic-text` stay inside the generated binding and
// `tether-render` (backend confinement). A consumer that wants to draw
// differently takes `prepare` through its own path.
//
// `Gen` is uniffi-bindgen-cs output and stays `internal` (Decisions/0004).

using Gen = global::uniffi.tether_ffi;

namespace Tether;

/// <summary>A GPU terminal surface.</summary>
public sealed class TerminalSurface : IAsyncDisposable, IDisposable
{
    private readonly Gen.RenderSurface _inner;
    private bool _disposed;

    private TerminalSurface(Gen.RenderSurface inner) => _inner = inner;

    /// <summary>
    /// Creates a surface for a Win32 <c>HWND</c>. The window must outlive the
    /// surface. A WinUI host gets the handle from
    /// <c>WindowNative.GetWindowHandle</c>.
    /// </summary>
    public static async Task<TerminalSurface> FromHwndAsync(
        nint hwnd, uint width, uint height)
    {
        var inner = await Gen.RenderSurface.FromHwnd(
            (ulong)hwnd, width, height).ConfigureAwait(false);
        return new TerminalSurface(inner);
    }

    /// <summary>Measures the monospaced face this surface will draw with.</summary>
    public FontMetrics Measure(float size)
    {
        var dto = _inner.Measure(size);
        return FontMetrics.FromAdvances(
            dto.Size, dto.NarrowAdvance, dto.WideAdvance, dto.LineHeight);
    }

    public static string[] FontFamilies() => Gen.TetherFfiMethods.RenderFontFamilies();

    public void SetFonts(string primary, string wide) => _inner.SetFonts(primary, wide);

    public void Resize(uint width, uint height) => _inner.Resize(width, height);

    /// <summary>Draws one frame with the consumer's palette and pointer marks.</summary>
    public void Draw(ScreenFrame frame, Palette palette, Overlay? overlay = null) =>
        _inner.Draw(Lower(frame), Lower(palette), overlay is null ? null : Lower(overlay));

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _inner.Dispose();
    }

    public ValueTask DisposeAsync()
    {
        Dispose();
        return ValueTask.CompletedTask;
    }

    // ---- lowering: public contract → generated types ----

    private static Gen.ScreenFrame Lower(ScreenFrame f) => new(
        f.Columns, f.Rows, f.CursorRow, f.CursorColumn,
        Lower(f.CursorShape), f.CursorVisible, f.AlternateScreen,
        f.ViewportOffset, f.HistoryLines, f.Title,
        f.Lines.Select(Lower).ToArray());

    private static Gen.ScreenRow Lower(ScreenRow r) =>
        new(r.Runs.Select(Lower).ToArray());

    private static Gen.StyledRun Lower(StyledRun r) =>
        new(r.Text, r.Columns, Lower(r.Style));

    private static Gen.CellStyle Lower(RunStyle s) => new(
        Lower(s.Foreground), Lower(s.Background),
        Lower(s.Underline), s.UnderlineColor is null ? null : Lower(s.UnderlineColor),
        s.Bold, s.Dim, s.Italic, s.Strikethrough, s.Inverse, s.Hidden);

    private static Gen.CellColor Lower(CellColor c) => c switch
    {
        CellColor.Named n => new Gen.CellColor.Named(Lower(n.Name)),
        CellColor.Indexed i => new Gen.CellColor.Indexed(i.Index),
        CellColor.Rgb rgb => new Gen.CellColor.Rgb(rgb.Red, rgb.Green, rgb.Blue),
        _ => throw new ArgumentOutOfRangeException(nameof(c)),
    };

    private static Gen.ColorName Lower(ColorName n) => n switch
    {
        ColorName.Black => Gen.ColorName.Black,
        ColorName.Red => Gen.ColorName.Red,
        ColorName.Green => Gen.ColorName.Green,
        ColorName.Yellow => Gen.ColorName.Yellow,
        ColorName.Blue => Gen.ColorName.Blue,
        ColorName.Magenta => Gen.ColorName.Magenta,
        ColorName.Cyan => Gen.ColorName.Cyan,
        ColorName.White => Gen.ColorName.White,
        ColorName.BrightBlack => Gen.ColorName.BrightBlack,
        ColorName.BrightRed => Gen.ColorName.BrightRed,
        ColorName.BrightGreen => Gen.ColorName.BrightGreen,
        ColorName.BrightYellow => Gen.ColorName.BrightYellow,
        ColorName.BrightBlue => Gen.ColorName.BrightBlue,
        ColorName.BrightMagenta => Gen.ColorName.BrightMagenta,
        ColorName.BrightCyan => Gen.ColorName.BrightCyan,
        ColorName.BrightWhite => Gen.ColorName.BrightWhite,
        ColorName.Foreground => Gen.ColorName.Foreground,
        ColorName.Background => Gen.ColorName.Background,
        ColorName.Cursor => Gen.ColorName.Cursor,
        _ => throw new ArgumentOutOfRangeException(nameof(n)),
    };

    private static Gen.UnderlineStyle Lower(UnderlineStyle u) => u switch
    {
        UnderlineStyle.None => Gen.UnderlineStyle.None,
        UnderlineStyle.Single => Gen.UnderlineStyle.Single,
        UnderlineStyle.Double => Gen.UnderlineStyle.Double,
        UnderlineStyle.Curly => Gen.UnderlineStyle.Curly,
        UnderlineStyle.Dotted => Gen.UnderlineStyle.Dotted,
        UnderlineStyle.Dashed => Gen.UnderlineStyle.Dashed,
        _ => throw new ArgumentOutOfRangeException(nameof(u)),
    };

    private static Gen.CaretShape Lower(CaretShape c) => c switch
    {
        CaretShape.Block => Gen.CaretShape.Block,
        CaretShape.Underline => Gen.CaretShape.Underline,
        CaretShape.Beam => Gen.CaretShape.Beam,
        CaretShape.Hidden => Gen.CaretShape.Hidden,
        _ => throw new ArgumentOutOfRangeException(nameof(c)),
    };

    private static Gen.PaletteDto Lower(Palette p)
    {
        var ansi = p.Normal.Concat(p.Bright).Select(c => new Gen.RgbaDto(
            c.Red, c.Green, c.Blue, c.Alpha)).ToArray();
        return new Gen.PaletteDto(
            new Gen.RgbaDto(p.Background.Red, p.Background.Green, p.Background.Blue, p.Background.Alpha),
            new Gen.RgbaDto(p.Foreground.Red, p.Foreground.Green, p.Foreground.Blue, p.Foreground.Alpha),
            new Gen.RgbaDto(p.Cursor.Red, p.Cursor.Green, p.Cursor.Blue, p.Cursor.Alpha),
            ansi);
    }

    private static Gen.OverlayDto Lower(Overlay o) => new(
        o.Selection is null
            ? null
            : new Gen.SelectionDto(
                (uint)o.Selection.Anchor.Column, (uint)o.Selection.Anchor.Row,
                (uint)o.Selection.Focus.Column, (uint)o.Selection.Focus.Row),
        o.LinkUnderlines
            .Select(u => new Gen.LinkUnderlineDto((uint)u.Row, (uint)u.Start, (uint)u.End, u.Confirmed))
            .ToArray(),
        new Gen.RgbaDto(o.SelectionColor.Red, o.SelectionColor.Green, o.SelectionColor.Blue, o.SelectionColor.Alpha),
        new Gen.RgbaDto(o.LinkColor.Red, o.LinkColor.Green, o.LinkColor.Blue, o.LinkColor.Alpha));
}
