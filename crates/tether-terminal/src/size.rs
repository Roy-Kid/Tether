//! How big the screen is, and where things are on it.

/// The terminal's dimensions, in character cells.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScreenSize {
    pub columns: u16,
    pub rows: u16,
}

impl ScreenSize {
    /// A zero-sized terminal is not a terminal; both dimensions are clamped to
    /// at least one so that nothing downstream has to handle an empty grid.
    pub fn new(columns: u16, rows: u16) -> Self {
        Self { columns: columns.max(1), rows: rows.max(1) }
    }
}

impl Default for ScreenSize {
    fn default() -> Self {
        Self { columns: 80, rows: 24 }
    }
}

/// A cell position in the visible screen, counted from the top-left.
///
/// Rows are viewport rows, not history rows: row 0 is what a consumer draws
/// at the top, whatever is scrolled above it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Position {
    pub row: u16,
    pub column: u16,
}

impl Position {
    pub fn new(row: u16, column: u16) -> Self {
        Self { row, column }
    }
}
