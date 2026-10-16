// One measurement of the monospaced font, reused for every cell.
//
// Ported from `TetherUI.FontMetrics`. The cell is a whole number of DIPs wide
// so that a column lands on the same place every time, and the font is then
// *spaced into* that cell rather than trusted to fill it. Those are two
// different numbers: a face can advance 8.04 at 13pt, and a grid built on 8
// that draws text at 8.04 is a grid whose eightieth column is three
// characters out.

namespace Tether;

/// <summary>Geometry of one monospaced cell, and the spacing that lands runs on it.</summary>
public sealed record FontMetrics(
    double Size,
    double CellWidth,
    double LineHeight,
    double NarrowAdvance,
    double WideAdvance)
{
    /// <summary>
    /// Builds metrics from advances already measured. The cell width is
    /// rounded to a whole DIP; the advances stay as the font reported them.
    /// </summary>
    public static FontMetrics FromAdvances(
        double size, double narrowAdvance, double wideAdvance, double lineHeight)
    {
        // Nearest, not up: rounding up added most of a point per column at
        // 13pt, and the text then had to be stretched by that much to keep up.
        var cellWidth = Math.Max(1.0, Math.Round(narrowAdvance));
        return new FontMetrics(size, cellWidth, Math.Max(1.0, lineHeight), narrowAdvance, wideAdvance);
    }

    /// <summary>The extra advance that makes <paramref name="characters"/> characters cover exactly <paramref name="cells"/> columns.</summary>
    public double Tracking(uint cells, int characters)
    {
        if (characters <= 0) return 0;
        var columns = (double)cells / characters;
        var advance = columns > 1.5 ? WideAdvance : NarrowAdvance;
        return columns * CellWidth - advance;
    }

    /// <summary>Left edge of a column, and the width a run of columns covers.</summary>
    public double CellX(uint column) => column * CellWidth;
    public double CellY(uint row) => row * LineHeight;
    public double CellsWidth(uint columns) => columns * CellWidth;

    /// <summary>
    /// How many cells fit. Floor, not nearest: a fraction of a cell is not a
    /// cell, and rounding up is how the last column was drawn past the clip.
    /// </summary>
    public ushort ColumnsFitting(double width) =>
        (ushort)Math.Clamp(Math.Floor(width / CellWidth), 1, 1000);

    public ushort RowsFitting(double height) =>
        (ushort)Math.Clamp(Math.Floor(height / LineHeight), 1, 500);
}
