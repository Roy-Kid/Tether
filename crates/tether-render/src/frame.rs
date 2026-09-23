//! The screen, in the shape a renderer draws.
//!
//! Not a cell grid and not `alacritty_terminal`'s types (spec §8). Rows are
//! long stretches of identical style and identical width, so a run is one
//! attributed string — which is also what a text renderer wants (spec §14).
//!
//! These types mirror the FFI contract (`tether-ffi`'s `ScreenFrame`) without
//! depending on it: `tether-ffi` reaches `tether-ssh` through `tether-core`,
//! and this crate must not (spec §3). The conversion is a field map at the
//! binding seam, not a rename of a dependency.

/// One of the palette entries a terminal names rather than resolves.
///
/// Still named here: the *consumer* owns the palette (Decision 0011), and a
/// light theme must be free to draw "red" as its own red.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Name {
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
    /// The theme's default text colour.
    Foreground,
    /// The theme's default background colour.
    Background,
    /// The colour the cursor is drawn in.
    Cursor,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Paint {
    Named(Name),
    /// An index into the 256-colour palette.
    Indexed(u8),
    Rgb { red: u8, green: u8, blue: u8 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Underline {
    None,
    Single,
    Double,
    Curly,
    Dotted,
    Dashed,
}

/// What the caret looks like. `Hidden` is a shape as well as a flag: a
/// full-screen program hides the cursor constantly while redrawing, and
/// drawing it anyway is how a terminal ends up with a block flickering
/// across the screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Caret {
    Block,
    Underline,
    Beam,
    Hidden,
}

/// Everything about a run's appearance except its text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RunStyle {
    pub foreground: Paint,
    pub background: Paint,
    pub underline: Underline,
    /// Set when the run carries its own underline colour; `None` means use
    /// the foreground.
    pub underline_color: Option<Paint>,
    pub bold: bool,
    pub dim: bool,
    pub italic: bool,
    pub strikethrough: bool,
    /// Foreground and background are to be swapped when drawing. Kept as a
    /// flag rather than pre-swapped, because a renderer may want to know.
    pub inverse: bool,
    /// The text is present but must not be drawn — what a shell uses while
    /// reading a password. The background is still painted, so the cell does
    /// not become a hole in a highlighted region.
    pub hidden: bool,
}

impl Default for RunStyle {
    fn default() -> Self {
        Self {
            foreground: Paint::Named(Name::Foreground),
            background: Paint::Named(Name::Background),
            underline: Underline::None,
            underline_color: None,
            bold: false,
            dim: false,
            italic: false,
            strikethrough: false,
            inverse: false,
            hidden: false,
        }
    }
}

/// A stretch of text on one row that looks the same all the way along, every
/// character of it covering the same number of columns.
///
/// Uniform width is part of the contract: a frontend draws a run as one
/// string and has to space that string to the grid from `columns /
/// characters`, which is a whole number of columns per character exactly when
/// the run does not mix widths. A row breaks where the width changes, as well
/// as where the style does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Run {
    pub text: String,
    /// How many columns the run covers. Not `text.count` — a wide character
    /// is one grapheme over two columns.
    pub columns: u32,
    pub style: RunStyle,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    pub runs: Vec<Run>,
}

/// One frame: everything a renderer needs to draw the screen once.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub columns: u32,
    pub rows: u32,
    pub cursor_row: u32,
    pub cursor_column: u32,
    pub cursor_shape: Caret,
    pub cursor_visible: bool,
    /// A full-screen program is running, so scrollback must not be shown.
    pub alternate_screen: bool,
    /// Lines between the bottom of this frame and the live screen. Zero means
    /// new output appears on what is being shown.
    pub viewport_offset: u32,
    /// How many lines of history exist behind the live screen.
    pub history_lines: u32,
    pub title: String,
    pub lines: Vec<Row>,
}

impl Frame {
    /// An empty frame of the given size in the default style.
    pub fn blank(columns: u32, rows: u32) -> Self {
        Self {
            columns,
            rows,
            cursor_row: 0,
            cursor_column: 0,
            cursor_shape: Caret::Block,
            cursor_visible: true,
            alternate_screen: false,
            viewport_offset: 0,
            history_lines: 0,
            title: String::new(),
            lines: (0..rows)
                .map(|_| Row {
                    runs: vec![Run {
                        text: " ".repeat(columns as usize),
                        columns,
                        style: RunStyle::default(),
                    }],
                })
                .collect(),
        }
    }
}
