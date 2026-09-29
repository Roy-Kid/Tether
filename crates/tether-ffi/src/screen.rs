//! The screen, in the shape a frontend draws.
//!
//! Not a cell grid. A cell-at-a-time surface would cross the FFI boundary
//! four thousand times per frame on a modest window, and every one of those
//! cells carries a `String`. Terminal rows are not random: they are long
//! stretches of identical style, so adjacent cells that look alike collapse
//! into one run with one string.
//!
//! That is also the shape a text renderer wants — a run is one attributed
//! string — so this is not a compression trick applied to an unnatural
//! model, it is the model (spec §14: no UI toolkit types here, and none of
//! `alacritty_terminal`'s types either).

use tether_core::terminal::{Color, CursorShape, NamedColor, Screen, Style, Underline};

/// One of the palette entries a terminal names rather than resolves.
///
/// Still named at the boundary: the *consumer* owns the palette, and a
/// frontend with a light theme must be free to draw "red" as its own red.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ColorName {
    Black,
    Red,
    Green,
    Yellow,
    Blue,
    Magenta,
    Cyan,
    White,
    BrightBlack,
    BrightRed,
    BrightGreen,
    BrightYellow,
    BrightBlue,
    BrightMagenta,
    BrightCyan,
    BrightWhite,
    Foreground,
    Background,
    Cursor,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CellColor {
    Named { name: ColorName },
    Indexed { index: u8 },
    Rgb { red: u8, green: u8, blue: u8 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum UnderlineStyle {
    None,
    Single,
    Double,
    Curly,
    Dotted,
    Dashed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CaretShape {
    Block,
    Underline,
    Beam,
    Hidden,
}

/// Everything about a run's appearance except its text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct CellStyle {
    pub foreground: CellColor,
    pub background: CellColor,
    pub underline: UnderlineStyle,
    pub underline_color: Option<CellColor>,
    pub bold: bool,
    pub dim: bool,
    pub italic: bool,
    pub strikethrough: bool,
    pub inverse: bool,
    pub hidden: bool,
}

/// A stretch of text on one row that looks the same all the way along, every
/// character of it covering the same number of columns.
///
/// Uniform width is part of the contract, not an accident of the data. A
/// frontend draws a run as one string and has to space that string to the
/// grid; it can only do that from `columns / characters`, which is a whole
/// number of columns per character exactly when the run does not mix widths.
/// So a row breaks where the width changes, as well as where the style does.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct StyledRun {
    pub text: String,
    /// How many columns the run covers. Not `text.count` — a wide character
    /// is one grapheme over two columns, and a frontend laying out a
    /// monospaced grid needs the column count to place the next run.
    pub columns: u32,
    pub style: CellStyle,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ScreenRow {
    pub runs: Vec<StyledRun>,
}

/// One row of a partial update, named by its place on the visible screen.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UpdatedRow {
    pub row: u32,
    pub line: ScreenRow,
}

/// What changed since the frontend last drew.
///
/// `Full` replaces the screen. `Rows` replaces those lines and the cursor.
/// `Idle` is a cursor or title change with no new cells.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FrameUpdate {
    Full {
        frame: ScreenFrame,
    },
    Rows {
        rows: Vec<UpdatedRow>,
        cursor_row: u32,
        cursor_column: u32,
        cursor_shape: CaretShape,
        cursor_visible: bool,
        title: String,
        viewport_offset: u32,
        history_lines: u32,
    },
    Idle {
        cursor_row: u32,
        cursor_column: u32,
        cursor_shape: CaretShape,
        cursor_visible: bool,
        title: String,
        viewport_offset: u32,
        history_lines: u32,
    },
}

/// One frame: everything a frontend needs to draw the screen once.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ScreenFrame {
    pub columns: u32,
    pub rows: u32,
    pub cursor_row: u32,
    pub cursor_column: u32,
    pub cursor_shape: CaretShape,
    pub cursor_visible: bool,
    /// A full-screen program is running, so scrollback must not be shown.
    pub alternate_screen: bool,
    /// Lines between the bottom of this frame and the live screen. Zero means
    /// new output appears on what is being shown.
    pub viewport_offset: u32,
    /// How many lines of history exist behind the live screen. Zero on the
    /// alternate screen, which keeps none.
    pub history_lines: u32,
    pub title: String,
    pub lines: Vec<ScreenRow>,
}

impl ScreenFrame {
    /// Builds a frame from a snapshot.
    ///
    /// Public because the arithmetic here — how runs collapse and how many
    /// columns each covers — is the contract a frontend lays out against,
    /// and a contract that cannot be tested from outside is not one.
    pub fn of(screen: &Screen, title: String) -> Self {
        Self {
            columns: screen.size.columns as u32,
            rows: screen.size.rows as u32,
            cursor_row: screen.cursor.position.row as u32,
            cursor_column: screen.cursor.position.column as u32,
            cursor_shape: caret(screen.cursor.shape),
            cursor_visible: screen.cursor.visible,
            alternate_screen: screen.modes.alternate_screen,
            viewport_offset: screen.viewport.offset.min(u32::MAX as usize) as u32,
            history_lines: screen.viewport.history.min(u32::MAX as usize) as u32,
            title,
            lines: screen.rows().map(row_of).collect(),
        }
    }
}

impl FrameUpdate {
    /// The next frame, copying only the rows the damage named.
    pub fn from_delta(delta: &tether_core::terminal::FrameDelta) -> Self {
        let cursor_row = delta.cursor.position.row as u32;
        let cursor_column = delta.cursor.position.column as u32;
        let cursor_shape = caret(delta.cursor.shape);
        let cursor_visible = delta.cursor.visible;
        let viewport_offset = delta.viewport.offset.min(u32::MAX as usize) as u32;
        let history_lines = delta.viewport.history.min(u32::MAX as usize) as u32;
        if let Some(screen) = &delta.full {
            return FrameUpdate::Full { frame: ScreenFrame::of(screen, delta.title.clone()) };
        }
        if delta.rows.is_empty() {
            return FrameUpdate::Idle {
                cursor_row,
                cursor_column,
                cursor_shape,
                cursor_visible,
                title: delta.title.clone(),
                viewport_offset,
                history_lines,
            };
        }
        FrameUpdate::Rows {
            rows: delta
                .rows
                .iter()
                .map(|(row, cells)| UpdatedRow { row: *row as u32, line: row_of(cells) })
                .collect(),
            cursor_row,
            cursor_column,
            cursor_shape,
            cursor_visible,
            title: delta.title.clone(),
            viewport_offset,
            history_lines,
        }
    }
}

/// Collapses a row's cells into runs of identical style and identical width.
fn row_of(cells: &[tether_core::terminal::Cell]) -> ScreenRow {
    let mut runs: Vec<StyledRun> = Vec::new();
    // The width the run being built is made of. A wide character next to a
    // narrow one starts a new run even in the same style, because a run is
    // what a frontend spaces to the grid in one piece.
    let mut width = 0;

    for cell in cells {
        let style = style_of(&cell.style);
        match runs.last_mut() {
            // Extending in place rather than rebuilding: a full row of plain
            // text is one allocation that grows, not eighty.
            Some(run) if run.style == style && width == cell.width => {
                run.text.push_str(&cell.text);
                run.columns += cell.width as u32;
            }
            _ => {
                width = cell.width;
                runs.push(StyledRun { text: cell.text.clone(), columns: cell.width as u32, style })
            }
        }
    }

    ScreenRow { runs }
}

fn style_of(style: &Style) -> CellStyle {
    CellStyle {
        foreground: color_of(style.foreground),
        background: color_of(style.background),
        underline: underline_of(style.underline),
        underline_color: style.underline_color.map(color_of),
        bold: style.bold,
        dim: style.dim,
        italic: style.italic,
        strikethrough: style.strikethrough,
        inverse: style.inverse,
        hidden: style.hidden,
    }
}

fn color_of(color: Color) -> CellColor {
    match color {
        Color::Named(name) => CellColor::Named { name: name_of(name) },
        Color::Indexed(index) => CellColor::Indexed { index },
        Color::Rgb { red, green, blue } => CellColor::Rgb { red, green, blue },
    }
}

fn name_of(name: NamedColor) -> ColorName {
    match name {
        NamedColor::Black => ColorName::Black,
        NamedColor::Red => ColorName::Red,
        NamedColor::Green => ColorName::Green,
        NamedColor::Yellow => ColorName::Yellow,
        NamedColor::Blue => ColorName::Blue,
        NamedColor::Magenta => ColorName::Magenta,
        NamedColor::Cyan => ColorName::Cyan,
        NamedColor::White => ColorName::White,
        NamedColor::BrightBlack => ColorName::BrightBlack,
        NamedColor::BrightRed => ColorName::BrightRed,
        NamedColor::BrightGreen => ColorName::BrightGreen,
        NamedColor::BrightYellow => ColorName::BrightYellow,
        NamedColor::BrightBlue => ColorName::BrightBlue,
        NamedColor::BrightMagenta => ColorName::BrightMagenta,
        NamedColor::BrightCyan => ColorName::BrightCyan,
        NamedColor::BrightWhite => ColorName::BrightWhite,
        NamedColor::Foreground => ColorName::Foreground,
        NamedColor::Background => ColorName::Background,
        NamedColor::Cursor => ColorName::Cursor,
    }
}

fn underline_of(underline: Underline) -> UnderlineStyle {
    match underline {
        Underline::None => UnderlineStyle::None,
        Underline::Single => UnderlineStyle::Single,
        Underline::Double => UnderlineStyle::Double,
        Underline::Curly => UnderlineStyle::Curly,
        Underline::Dotted => UnderlineStyle::Dotted,
        Underline::Dashed => UnderlineStyle::Dashed,
    }
}

fn caret(shape: CursorShape) -> CaretShape {
    match shape {
        CursorShape::Block => CaretShape::Block,
        CursorShape::Underline => CaretShape::Underline,
        CursorShape::Beam => CaretShape::Beam,
        CursorShape::Hidden => CaretShape::Hidden,
    }
}
