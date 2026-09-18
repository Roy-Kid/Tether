//! How a cell looks.
//!
//! These are our own types. A consumer that matched on `alacritty_terminal`'s
//! colour enum would be pinned to the engine we happen to use (spec §8).

/// One of the sixteen names a terminal palette gives its base colours, plus
/// the two the theme supplies.
///
/// Named rather than resolved to RGB because the *consumer* owns the palette:
/// a renderer with a light theme must be able to draw "red" as its own red.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NamedColor {
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
    /// The colour the cursor should be drawn in.
    Cursor,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Color {
    Named(NamedColor),
    /// An index into the 256-colour palette.
    Indexed(u8),
    Rgb {
        red: u8,
        green: u8,
        blue: u8,
    },
}

/// How text in a cell is decorated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Underline {
    None,
    Single,
    Double,
    Curly,
    Dotted,
    Dashed,
}

/// Everything about a cell's appearance except its text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Style {
    pub foreground: Color,
    pub background: Color,
    pub underline: Underline,
    /// Set when the cell carries its own underline colour; `None` means use
    /// the foreground, which is what every terminal does by default.
    pub underline_color: Option<Color>,
    pub bold: bool,
    pub dim: bool,
    pub italic: bool,
    pub strikethrough: bool,
    /// Foreground and background are to be swapped when drawing. Kept as a
    /// flag rather than pre-swapped, because a renderer may want to know.
    pub inverse: bool,
    /// The text is present but must not be drawn — what a shell uses while
    /// reading a password.
    pub hidden: bool,
}

impl Default for Style {
    fn default() -> Self {
        Self {
            foreground: Color::Named(NamedColor::Foreground),
            background: Color::Named(NamedColor::Background),
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
