//! What is on the screen right now.

use crate::scroll::Viewport;
use crate::size::{Position, ScreenSize};
use crate::style::Style;

/// One cell of the grid.
///
/// `text` is a whole grapheme cluster, not a scalar: `é` written as `e` plus a
/// combining accent is one cell holding two scalars, and a family emoji is one
/// cell holding several joined by zero-width joiners. A consumer that treated
/// this as a `char` would split exactly the sequences people notice
/// (spec §12).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cell {
    pub text: String,
    /// How many columns this cell occupies: 1 for most text, 2 for wide
    /// characters such as CJK and most emoji.
    ///
    /// A double-width cell is reported once, at its left-hand column, with
    /// `width == 2`. The column it covers to the right is not a cell of its
    /// own — the engine's internal spacer is not a thing a consumer should
    /// have to know about.
    pub width: u8,
    pub style: Style,
}

impl Cell {
    /// An empty cell in the default style.
    pub fn blank() -> Self {
        Self { text: " ".to_string(), width: 1, style: Style::default() }
    }

    /// True when this cell would draw nothing: no text and no background of
    /// its own. Renderers skip these.
    pub fn is_blank(&self) -> bool {
        self.text == " " && self.style == Style::default()
    }
}

/// Where the cursor is and what it looks like.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cursor {
    pub position: Position,
    pub shape: CursorShape,
    /// False while the far side has asked for the cursor to be hidden — which
    /// full-screen programs do constantly while redrawing.
    pub visible: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CursorShape {
    Block,
    Underline,
    Beam,
    /// The cursor is hidden by the program, not merely blinking.
    Hidden,
}

/// Terminal modes a consumer has to know about to behave correctly.
///
/// Not the full DEC mode set: these are the ones that change what a *frontend*
/// must do. A mode nobody outside the engine acts on stays inside the engine
/// (law: hide decisions, expose contracts).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Modes {
    /// The alternate screen is active — a full-screen program is running, and
    /// scrollback must not be shown.
    pub alternate_screen: bool,
    /// Pasted text must be wrapped in bracketing sequences so the far side can
    /// tell a paste from typing.
    pub bracketed_paste: bool,
    /// Cursor keys must be encoded in application form. Getting this wrong is
    /// why arrow keys print `^[[A` inside some programs.
    pub application_cursor_keys: bool,
    /// The far side wants mouse events reported.
    pub mouse_reporting: bool,
    /// Text wraps at the right margin rather than overwriting the last column.
    pub line_wrap: bool,
}

/// A snapshot of the visible screen.
///
/// Owned, not borrowed: a consumer renders on its own schedule, and handing
/// out a borrow of the live grid would make the engine's locking its problem.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Screen {
    pub size: ScreenSize,
    pub cursor: Cursor,
    pub modes: Modes,
    /// Where these rows were taken from, and how much history is behind
    /// them. A renderer drawing a scrollbar needs both to agree with the
    /// rows it was handed (spec §12).
    pub viewport: Viewport,
    /// Row-major, `size.rows` rows of `size.columns` cells. A double-width
    /// cell is followed by no entry for the column it covers, so a row may
    /// hold fewer cells than there are columns.
    rows: Vec<Vec<Cell>>,
}

impl Screen {
    pub(crate) fn new(
        size: ScreenSize,
        cursor: Cursor,
        modes: Modes,
        viewport: Viewport,
        rows: Vec<Vec<Cell>>,
    ) -> Self {
        Self { size, cursor, modes, viewport, rows }
    }

    pub fn row(&self, row: u16) -> Option<&[Cell]> {
        self.rows.get(row as usize).map(Vec::as_slice)
    }

    pub fn rows(&self) -> impl Iterator<Item = &[Cell]> {
        self.rows.iter().map(Vec::as_slice)
    }

    /// The row's text with trailing blanks removed — what a test asserts on
    /// and what a person would say the line "says".
    pub fn row_text(&self, row: u16) -> String {
        self.row(row)
            .map(|cells| {
                let line: String = cells.iter().map(|cell| cell.text.as_str()).collect();
                line.trim_end().to_string()
            })
            .unwrap_or_default()
    }

    /// Every row's text, trailing blank rows removed.
    pub fn text(&self) -> String {
        let mut lines: Vec<String> = (0..self.size.rows).map(|r| self.row_text(r)).collect();
        while lines.last().is_some_and(String::is_empty) {
            lines.pop();
        }
        lines.join("\n")
    }
}
