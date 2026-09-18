//! Moving the viewport over what has already gone past.
//!
//! A terminal keeps the lines that scrolled off the top, and being able to
//! look at them is not a convenience — output a person cannot go back to is
//! output they did not receive. The engine keeps the history; this is the
//! vocabulary for moving over it.

/// Where to put the viewport.
///
/// Named by intent rather than by line arithmetic. `PageUp` is not
/// `Lines(rows)` at the call site: how much a page is depends on the screen,
/// which the caller would have to ask for and could get wrong between the
/// asking and the scrolling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scroll {
    /// Positive goes back into history, negative comes forward.
    Lines(i32),
    PageUp,
    PageDown,
    /// The oldest line still kept.
    Oldest,
    /// Back to the live screen, where new output appears.
    ///
    /// Where a terminal goes the moment someone types: a keystroke whose
    /// echo lands somewhere off-screen reads as a terminal that ignored it.
    Live,
}

/// How far back the viewport is, and how far back it could go.
///
/// Carried on every [`Screen`] rather than fetched separately: a renderer
/// drawing a scrollbar needs both numbers to agree with the rows it was
/// handed, and two calls could straddle a change.
///
/// [`Screen`]: crate::Screen
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Viewport {
    /// Lines between the bottom of the viewport and the live screen. Zero
    /// means the viewport is live.
    pub offset: usize,
    /// How many lines of history exist behind the live screen.
    ///
    /// Zero while a full-screen program is running: the alternate screen
    /// keeps no history, which is why scrollback must not be offered there.
    pub history: usize,
}

impl Viewport {
    /// True when new output will appear on the screen being shown.
    pub fn is_live(&self) -> bool {
        self.offset == 0
    }
}
