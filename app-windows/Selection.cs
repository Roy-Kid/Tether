// Text selection on the grid, and the clipboard actions that follow.
//
// A point names a cell; the selection is a rectangle of cells. Copy takes
// the run text in that rectangle; paste is a `TerminalInput.Paste` and is
// bracketed by the engine (spec §12), not by us.

using Tether;

namespace TetherApp;

/// <summary>How to turn a <see cref="Tether.Selection"/> into text.</summary>
public static class SelectionText
{
    /// <summary>The text inside the selection, as the runs on the frame give it.</summary>
    public static string Text(this Selection selection, ScreenFrame frame)
    {
        var start = new Cell(
            Math.Min(selection.Anchor.Column, selection.Focus.Column),
            Math.Min(selection.Anchor.Row, selection.Focus.Row));
        var end = new Cell(
            Math.Max(selection.Anchor.Column, selection.Focus.Column),
            Math.Max(selection.Anchor.Row, selection.Focus.Row));
        if (start == end) return "";

        var lines = new List<string>();
        for (var row = start.Row; row <= end.Row && row < frame.Lines.Length; row++)
        {
            var line = LineText(
                frame.Lines[row],
                row == start.Row ? start.Column : 0,
                row == end.Row ? end.Column : int.MaxValue);
            lines.Add(line.TrimEnd());
        }
        return string.Join(Environment.NewLine, lines);
    }

    /// <summary>Whether a drag covers nothing.</summary>
    public static bool IsEmpty(this Selection selection) =>
        selection.Anchor == selection.Focus;

    /// <summary>
    /// The word under a cell, as a selection. A word is a run of characters
    /// that is not whitespace — the same rule every terminal uses for
    /// double-click, so `src/main.rs:12` selects as one word and
    /// `hello world` does not.
    /// </summary>
    public static Selection? WordAt(ScreenFrame frame, Cell cell)
    {
        if (cell.Row < 0 || cell.Row >= frame.Lines.Length) return null;
        var row = frame.Lines[cell.Row];

        // Walk the row, tracking which character index covers which column.
        var text = new System.Text.StringBuilder();
        var columnStarts = new List<int>(); // column -> index into text
        var column = 0;
        foreach (var run in row.Runs)
        {
            var chars = run.Text.EnumerateRunes().ToList();
            var per = chars.Count == 0 ? 1.0 : (double)run.Columns / chars.Count;
            for (var i = 0; i < chars.Count; i++)
            {
                var width = Math.Max(1, (int)Math.Round(per));
                for (var c = 0; c < width; c++) columnStarts.Add(text.Length);
                text.Append(chars[i]);
                column += width;
            }
        }
        if (text.Length == 0) return null;

        var index = cell.Column >= 0 && cell.Column < columnStarts.Count
            ? columnStarts[cell.Column]
            : -1;
        if (index < 0 || index >= text.Length) return null;
        if (char.IsWhiteSpace(text[index])) return null;

        var start = index;
        while (start > 0 && !char.IsWhiteSpace(text[start - 1])) start--;
        var end = index + 1;
        while (end < text.Length && !char.IsWhiteSpace(text[end])) end++;

        // Map character indices back to columns.
        var startColumn = columnStarts.IndexOf(start);
        var endColumn = columnStarts.IndexOf(end - 1);
        if (startColumn < 0) startColumn = 0;
        if (endColumn < 0) endColumn = cell.Column;

        return new Selection(
            new Cell(startColumn, cell.Row),
            new Cell(endColumn, cell.Row));
    }

    /// <summary>The whole line under a cell. Triple-click's answer.</summary>
    public static Selection LineAt(ScreenFrame frame, Cell cell)
    {
        if (cell.Row < 0 || cell.Row >= frame.Lines.Length)
        {
            return new Selection(cell, cell);
        }
        var columns = frame.Lines[cell.Row].Runs.Sum(r => (int)r.Columns);
        return new Selection(new Cell(0, cell.Row), new Cell(Math.Max(0, columns - 1), cell.Row));
    }

    private static string LineText(ScreenRow row, int fromColumn, int toColumn)
    {
        var text = new System.Text.StringBuilder();
        var column = 0;
        foreach (var run in row.Runs)
        {
            var runStart = column;
            var runEnd = column + (int)run.Columns - 1;
            column += (int)run.Columns;

            if (runEnd < fromColumn || runStart > toColumn) continue;

            // Take the characters of the run that fall inside, by columns.
            var chars = run.Text.EnumerateRunes().ToList();
            if (chars.Count == 0) continue;
            var per = (double)run.Columns / chars.Count;

            for (var i = 0; i < chars.Count; i++)
            {
                var cellStart = runStart + (int)(i * per);
                var cellEnd = runStart + (int)((i + 1) * per) - 1;
                if (cellEnd < fromColumn || cellStart > toColumn) continue;
                text.Append(chars[i]);
            }
        }
        return text.ToString();
    }
}
