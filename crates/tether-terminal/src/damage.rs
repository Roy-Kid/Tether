//! What changed since the consumer last looked.
//!
//! Damage is part of the contract, not an optimisation (spec §12). A consumer
//! that had to diff whole screens to find a one-character edit would make
//! every keystroke cost a full frame, and no amount of GPU makes that right.

use crate::screen::{Cursor, Modes};

/// Which parts of the grid changed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScreenDamage {
    /// Nothing changed.
    None,
    /// Specific spans of specific rows changed.
    Rows(Vec<RowSpan>),
    /// Everything must be redrawn — a resize, a screen switch, a reset, or
    /// simply more change than is worth describing.
    Full,
}

/// A contiguous run of changed cells within one row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RowSpan {
    pub row: u16,
    /// Inclusive.
    pub first_column: u16,
    /// Inclusive.
    pub last_column: u16,
}

/// Everything that changed since [`take_changes`](crate::Terminal::take_changes)
/// was last called.
///
/// One type rather than several streams: a consumer wants to know what to do
/// for *this* frame, and splitting that across callbacks would make it
/// reassemble an order we already know.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Changes {
    pub screen: ScreenDamage,
    /// Set when the cursor moved, changed shape, or appeared or disappeared.
    pub cursor: Option<Cursor>,
    /// Set when the far side changed the window title.
    pub title: Option<String>,
    /// Set when any of the modes a frontend acts on changed.
    pub modes: Option<Modes>,
    /// How many lines scrolled off the top into history since last time.
    /// A consumer that keeps its own scrollback view needs this to stay put.
    pub scrolled_lines: usize,
    /// The far side rang the bell.
    pub bell: bool,
}

impl Default for ScreenDamage {
    fn default() -> Self {
        Self::None
    }
}

impl Changes {
    /// True when nothing at all happened, so a consumer can skip a frame
    /// without inspecting six fields.
    pub fn is_empty(&self) -> bool {
        self.screen == ScreenDamage::None
            && self.cursor.is_none()
            && self.title.is_none()
            && self.modes.is_none()
            && self.scrolled_lines == 0
            && !self.bell
    }
}
