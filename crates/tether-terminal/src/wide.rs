//! How many columns a cell of the engine's grid is, decided in one place.
//!
//! The engine marks a wide character's right half with a spacer, and that
//! record is not always intact: reflow onto a narrower screen, or an insert
//! that pushes the character to the edge of its row, can leave the left half
//! in the last column with its spacer gone. Asked separately by the screen,
//! history and the link finder, the question was answered three ways, and
//! the fuzzers found each that got it wrong — a two-column row that claimed
//! three, a link that ended past the edge. Every reader asks here.

use alacritty_terminal::grid::Row;
use alacritty_terminal::index::Column;
use alacritty_terminal::term::cell::{Cell, Flags};

/// The columns the cell at `column` covers: two only when the engine really
/// did reserve the column to its right. Whether a column *index* remains is
/// not the same question — the spacer is the engine's own record of the
/// reservation, so it is what gets asked.
pub(crate) fn width(row: &Row<Cell>, column: usize) -> u8 {
    let wide = row[Column(column)].flags.contains(Flags::WIDE_CHAR)
        && column + 1 < row.len()
        && row[Column(column + 1)].flags.contains(Flags::WIDE_CHAR_SPACER);
    if wide { 2 } else { 1 }
}

/// Whether the cell at `column` is the right half of the wide character
/// before it, and so covered by that one rather than a cell of its own. An
/// orphaned spacer is not: it still occupies a column.
pub(crate) fn is_right_half(row: &Row<Cell>, column: usize) -> bool {
    column > 0
        && row[Column(column)].flags.contains(Flags::WIDE_CHAR_SPACER)
        && row[Column(column - 1)].flags.contains(Flags::WIDE_CHAR)
}
