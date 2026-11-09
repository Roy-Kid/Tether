//! Choosing text in a frame: the Mac `GridText`.
//!
//! A run is graphemes of one width, so a column is walked rather than
//! counted in characters: the right half of a wide character is that
//! character, and a hidden cell is a password, which never reaches the
//! clipboard. A selection whose rows are one link (its own spans) arrives
//! with ⌘-click links.

use tether_ffi::{ScreenFrame, ScreenRow};

/// How a drag chooses text: a character drag is the cells under the
/// pointer; a word or a line drag, from a double or triple click, grows by
/// that unit.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Character,
    Word,
    Line,
}

/// One cell, in the frame's own rows and columns.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Point {
    pub row: usize,
    pub column: usize,
}

impl Point {
    pub fn new(row: usize, column: usize) -> Self {
        Self { row, column }
    }

    /// Reading order, strictly.
    fn before(self, other: Self) -> bool {
        self.row < other.row || (self.row == other.row && self.column < other.column)
    }
}

/// The cells a drag covers. `anchor` is where it began, `head` where it is
/// now, in either order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Selection {
    pub anchor: Point,
    pub head: Point,
}

impl Selection {
    pub fn start(self) -> Point {
        if self.head.before(self.anchor) { self.head } else { self.anchor }
    }

    pub fn end(self) -> Point {
        if self.head.before(self.anchor) { self.anchor } else { self.head }
    }
}

/// One row's covered columns; `end` is one past the last.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Span {
    pub row: usize,
    pub start: usize,
    pub end: usize,
}

pub fn select(kind: Kind, from: Point, to: Point, frame: &ScreenFrame) -> Option<Selection> {
    match kind {
        Kind::Character => Some(Selection { anchor: from, head: to }),
        Kind::Word => words(frame, from, to),
        Kind::Line => lines(frame, from, to),
    }
}

/// The text a selection copies. Trailing blanks of each row go; a row
/// break is a newline.
pub fn text(frame: &ScreenFrame, selection: Selection) -> String {
    let columns = frame.columns as usize;
    let (start, end) = (selection.start(), selection.end());
    if columns == 0 {
        return String::new();
    }
    let mut copied = Vec::new();
    for row in start.row..=end.row {
        let Some(line) = frame.lines.get(row) else { continue };
        let from = if row == start.row { start.column } else { 0 };
        let through = if row == end.row { end.column } else { columns - 1 };
        copied.push(slice(line, from, through).trim_end().to_owned());
    }
    copied.join("\n")
}

/// One span per row. A wide character is covered whole when any of its
/// columns is, so the highlight matches the text that is copied.
pub fn spans(selection: Selection, frame: &ScreenFrame) -> Vec<Span> {
    let (columns, rows) = (frame.columns as usize, frame.rows as usize);
    let (start, end) = (selection.start(), selection.end());
    if columns == 0 || rows == 0 {
        return Vec::new();
    }
    (start.row..=end.row.min(rows - 1))
        .filter_map(|row| {
            let from = if row == start.row { start.column } else { 0 };
            let through = if row == end.row { end.column } else { columns - 1 };
            let (mut low, mut high) = (from, through);
            for cluster in frame.lines.get(row).map(clusters).unwrap_or_default() {
                let last = cluster.column + cluster.width - 1;
                if last >= from && cluster.column <= through {
                    low = low.min(cluster.column);
                    high = high.max(last);
                }
            }
            let start = low.min(columns);
            let end = (high + 1).clamp(start, columns);
            (end > start).then_some(Span { row, start, end })
        })
        .collect()
}

#[derive(Clone, Debug, PartialEq)]
struct Cluster {
    text: String,
    column: usize,
    width: usize,
}

fn clusters(row: &ScreenRow) -> Vec<Cluster> {
    let mut column = 0;
    let mut result = Vec::new();
    for run in &row.runs {
        let glyphs: Vec<char> = run.text.chars().collect();
        let count = glyphs.len();
        if count == 0 || run.columns == 0 {
            continue;
        }
        let (base, extra) = (run.columns as usize / count, run.columns as usize % count);
        for (index, glyph) in glyphs.into_iter().enumerate() {
            let width = (base + if index == count - 1 { extra } else { 0 }).max(1);
            // A hidden cell keeps its column; the character is a secret.
            let text = if run.style.hidden { " ".to_owned() } else { glyph.to_string() };
            result.push(Cluster { text, column, width });
            column += width;
        }
    }
    result
}

fn is_word(cluster: &Cluster) -> bool {
    cluster.text.chars().any(|c| !c.is_whitespace())
}

fn slice(row: &ScreenRow, from: usize, through: usize) -> String {
    if through < from {
        return String::new();
    }
    clusters(row)
        .into_iter()
        .filter(|cluster| cluster.column + cluster.width > from && cluster.column <= through)
        .map(|cluster| cluster.text)
        .collect()
}

fn word_span(frame: &ScreenFrame, at: Point) -> Option<(Point, Point)> {
    let glyphs = clusters(frame.lines.get(at.row)?);
    let index = glyphs
        .iter()
        .position(|g| g.column <= at.column && at.column < g.column + g.width)
        .filter(|&index| is_word(&glyphs[index]))?;
    let lower = (0..=index).rev().take_while(|&i| is_word(&glyphs[i])).last().unwrap_or(index);
    let upper = (index..glyphs.len()).take_while(|&i| is_word(&glyphs[i])).last().unwrap_or(index);
    Some((
        Point::new(at.row, glyphs[lower].column),
        Point::new(at.row, glyphs[upper].column + glyphs[upper].width - 1),
    ))
}

fn words(frame: &ScreenFrame, from: Point, to: Point) -> Option<Selection> {
    let (start, end) = (word_span(frame, from), word_span(frame, to));
    if start.is_none() && end.is_none() && from == to {
        return None;
    }
    let (a, b) = (start.unwrap_or((from, from)), end.unwrap_or((to, to)));
    let points = [a.0, a.1, b.0, b.1];
    let first = points.iter().copied().reduce(|x, y| if y.before(x) { y } else { x })?;
    let last = points.iter().copied().reduce(|x, y| if x.before(y) { y } else { x })?;
    Some(Selection { anchor: first, head: last })
}

fn lines(frame: &ScreenFrame, from: Point, to: Point) -> Option<Selection> {
    let last = frame.lines.len().checked_sub(1)?;
    let top = from.row.min(to.row).min(last);
    let bottom = from.row.max(to.row).min(last);
    let end = clusters(&frame.lines[bottom])
        .iter()
        .rev()
        .find(|cluster| is_word(cluster))
        .map(|cluster| cluster.column + cluster.width - 1)
        .unwrap_or(0);
    Some(Selection { anchor: Point::new(top, 0), head: Point::new(bottom, end) })
}

#[cfg(test)]
mod tests {
    use tether_ffi::{
        CaretShape, CellColor, CellStyle, ColorName, MouseTracking, StyledRun, UnderlineStyle,
    };

    use super::*;

    fn style(hidden: bool) -> CellStyle {
        CellStyle {
            foreground: CellColor::Named { name: ColorName::Foreground },
            background: CellColor::Named { name: ColorName::Background },
            underline: UnderlineStyle::None,
            underline_color: None,
            bold: false,
            dim: false,
            italic: false,
            strikethrough: false,
            inverse: false,
            hidden,
        }
    }

    fn run(text: &str, columns: u32, hidden: bool) -> StyledRun {
        StyledRun { text: text.to_owned(), columns, style: style(hidden) }
    }

    fn row(text: &str) -> ScreenRow {
        ScreenRow { runs: vec![run(text, text.chars().count() as u32, false)] }
    }

    fn screen(lines: Vec<ScreenRow>, columns: u32) -> ScreenFrame {
        ScreenFrame {
            columns,
            rows: lines.len() as u32,
            cursor_row: 0,
            cursor_column: 0,
            cursor_shape: CaretShape::Block,
            cursor_visible: true,
            alternate_screen: false,
            mouse: MouseTracking::Off,
            viewport_offset: 0,
            history_lines: 0,
            title: String::new(),
            lines,
        }
    }

    #[test]
    fn a_drag_copies_rows_without_trailing_blanks() {
        let frame = screen(vec![row("hello world   "), row("second line   ")], 14);
        let selection =
            select(Kind::Character, Point::new(0, 6), Point::new(1, 5), &frame).unwrap();
        assert_eq!(text(&frame, selection), "world\nsecond");
        // Backwards is the same selection.
        let back = select(Kind::Character, Point::new(1, 5), Point::new(0, 6), &frame).unwrap();
        assert_eq!(text(&frame, back), "world\nsecond");
    }

    #[test]
    fn a_double_click_takes_the_word_and_a_triple_the_line() {
        let frame = screen(vec![row("cargo build --release   ")], 24);
        let word = select(Kind::Word, Point::new(0, 8), Point::new(0, 8), &frame).unwrap();
        assert_eq!(text(&frame, word), "build");
        let line = select(Kind::Line, Point::new(0, 3), Point::new(0, 3), &frame).unwrap();
        assert_eq!(text(&frame, line), "cargo build --release");
        assert!(select(Kind::Word, Point::new(0, 22), Point::new(0, 22), &frame).is_none());
    }

    #[test]
    fn a_wide_character_is_covered_whole_and_copied_once() {
        let frame = screen(
            vec![ScreenRow {
                runs: vec![run("a", 1, false), run("中文", 4, false), run("b", 1, false)],
            }],
            6,
        );
        // Column 2 is the right half of 中.
        let selection =
            select(Kind::Character, Point::new(0, 2), Point::new(0, 3), &frame).unwrap();
        assert_eq!(text(&frame, selection), "中文");
        assert_eq!(spans(selection, &frame), [Span { row: 0, start: 1, end: 5 }]);
    }

    #[test]
    fn a_hidden_cell_never_reaches_the_clipboard() {
        let frame = screen(
            vec![ScreenRow {
                runs: vec![run("pw:", 3, false), run("secret", 6, true), run("!", 1, false)],
            }],
            10,
        );
        let selection =
            select(Kind::Character, Point::new(0, 0), Point::new(0, 9), &frame).unwrap();
        assert_eq!(text(&frame, selection), "pw:      !");
    }

    #[test]
    fn spans_cover_every_row_between() {
        let frame = screen(vec![row("one"), row("two"), row("six")], 3);
        let selection = Selection { anchor: Point::new(2, 1), head: Point::new(0, 1) };
        assert_eq!(
            spans(selection, &frame),
            [
                Span { row: 0, start: 1, end: 3 },
                Span { row: 1, start: 0, end: 3 },
                Span { row: 2, start: 0, end: 2 }
            ]
        );
    }
}
