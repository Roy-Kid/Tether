using Tether;
using System.Globalization;

internal static class Frames
{
    internal static void Validate(ScreenFrame frame)
    {
        if (frame.Lines.Length != frame.Rows) throw new InvalidDataException("Fixture row count does not match grid");
        foreach (var row in frame.Lines)
        {
            if (row.Runs.Sum(run => (long)run.Columns) != frame.Columns)
                throw new InvalidDataException("Fixture does not fill its row");
            foreach (var run in row.Runs)
            {
                var graphemes = StringInfo.ParseCombiningCharacters(run.Text).Length;
                if (graphemes == 0 && run.Columns == 0) continue;
                if (graphemes == 0 || run.Columns % graphemes != 0 || run.Columns / graphemes is < 1 or > 2)
                    throw new InvalidDataException("Fixture mixes grapheme column widths within one run");
            }
        }
    }

    internal static void VerifyFixtures()
    {
        foreach (var (columns, rows) in new[] { (80u, 24u), (120u, 40u), (200u, 60u), (400u, 100u) })
            foreach (var shape in new[] { "fonts", "prose", "highlighted", "worstCase" })
            {
                var frame = Create(columns, rows, shape);
                Validate(frame);
                Validate(Update(frame, shape, "scroll", 42));
            }
        var invalid = Create(3, 1, "prose") with {
            Lines = new[] { new ScreenRow(new[] { new StyledRun("😀 ", 3, RunStyle.Default) }) }
        };
        try { Validate(invalid); }
        catch (InvalidDataException) { return; }
        throw new InvalidDataException("Mixed-width negative control was accepted");
    }

    internal static ScreenFrame Create(uint columns, uint rows, string shape) => new(
        columns, rows, 0, 0, CaretShape.Block, true, false, 0, 0, "renderer evaluation",
        Enumerable.Range(0, (int)rows).Select(row => Row(columns, shape, row)).ToArray());

    internal static ScreenFrame Update(ScreenFrame frame, string shape, string mode, int tick)
    {
        if (mode == "line")
        {
            var lines = (ScreenRow[])frame.Lines.Clone();
            lines[tick % lines.Length] = Row(frame.Columns, shape, tick);
            return frame with { Lines = lines };
        }
        if (mode is "scroll" or "lifecycle")
            return frame with { Lines = frame.Lines.Skip(1).Append(Row(frame.Columns, shape, tick)).ToArray() };
        return frame with { CursorColumn = (uint)tick % frame.Columns, CursorVisible = tick % 60 < 30 };
    }

    private static ScreenRow Row(uint columns, string shape, int seed)
    {
        if (shape == "fonts")
        {
            var runs = new List<StyledRun>();
            uint used = 0;
            // The screen contract groups equal-width graphemes into a run.
            // Keep two-column emoji separate from one-column spaces.
            foreach (var (text, width) in new[] { ("ABC 0123 ", 9u), ("中文，", 6u), ("e\u0301 ", 2u), ("😀", 2u), (" ", 1u),
                ("👩‍💻", 2u), (" ", 1u), ("┌─┬─┐ ", 6u), ("éΩЖ ", 4u), ("fallback ", 9u) })
            {
                if (used + width > columns) break;
                runs.Add(new(text, width, Style(seed, true)));
                used += width;
            }
            if (used < columns) runs.Add(new(new string(' ', (int)(columns - used - 1)) + "|", columns - used, RunStyle.Default));
            return new(runs.ToArray());
        }
        var count = shape == "worstCase" ? (int)columns : shape == "highlighted" ? 6 : 1;
        return new(Enumerable.Range(0, count).Select(part => {
            var start = (uint)(part * columns / count);
            var end = (uint)((part + 1) * columns / count);
            return new StyledRun(new string((char)('A' + (seed + part) % 26), (int)(end - start)),
                end - start, Style(seed + part, false));
        }).ToArray());
    }

    private static RunStyle Style(int seed, bool fonts) => RunStyle.Default with {
        Foreground = new CellColor.Indexed((byte)(16 + seed % 216)),
        Bold = fonts && seed % 3 == 1, Italic = fonts && seed % 3 == 2,
        Underline = fonts ? (UnderlineStyle)(seed % 6) : UnderlineStyle.None,
        Strikethrough = fonts && seed % 4 == 0
    };
}
