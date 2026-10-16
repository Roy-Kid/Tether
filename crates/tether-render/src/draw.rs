//! What to paint, in the shape any backend can consume.
//!
//! Plain data. No `wgpu`, no `glyphon`, no `cosmic-text`, no UI toolkit type
//! (spec §8, §14): a headless test must be able to exercise a frame with no
//! GPU and no window linked. The GPU renderer turns this into a pass; a
//! software renderer could turn it into pixels; a test asserts against it
//! directly.

/// A straight colour, alpha included.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rgba {
    pub red: f32,
    pub green: f32,
    pub blue: f32,
    pub alpha: f32,
}

impl Rgba {
    pub const fn new(red: f32, green: f32, blue: f32, alpha: f32) -> Self {
        Self { red, green, blue, alpha }
    }

    /// As four bytes, the form a GPU vertex wants.
    pub fn to_bytes(self) -> [u8; 4] {
        fn byte(value: f32) -> u8 {
            (value.clamp(0.0, 1.0) * 255.0).round() as u8
        }
        [byte(self.red), byte(self.green), byte(self.blue), byte(self.alpha)]
    }

    pub fn with_alpha(self, alpha: f32) -> Self {
        Self { alpha, ..self }
    }
}

/// A filled rectangle — a cell background, a selection, a cursor body.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BgRect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub color: Rgba,
}

/// One attributed string placed on the grid.
///
/// `width` is the box the run covers (`columns × cell_width`), not the
/// string's own advance. The backend spaces the glyphs into that box — that
/// is what keeps the eightieth column where the cursor is.
#[derive(Debug, Clone, PartialEq)]
pub struct TextRun {
    pub font_size: f32,
    pub cell_width: f32,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub text: String,
    pub color: Rgba,
    /// Extra advance per character so `text` covers exactly `width`.
    pub tracking: f32,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    /// Underline colour when it differs from the text; `None` means the text
    /// colour, which is what every terminal does by default.
    pub underline_color: Option<Rgba>,
    pub strikethrough: bool,
}

/// The caret, as a box. The glyph underneath stays readable inside a block
/// caret because the box is drawn with alpha, not painted opaque and then
/// re-drawn.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CursorQuad {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub color: Rgba,
    pub shape: crate::frame::Caret,
}

/// A cell on the grid.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cell {
    pub column: u32,
    pub row: u32,
}

/// A run of columns on one row. `end` is exclusive.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellSpan {
    pub row: u32,
    pub start: u32,
    pub end: u32,
}

/// The pointer's own marks: a selection, and the underlines under links.
///
/// The frontend contract already carries selection (spec §14). Links are
/// Decision/0015: the terminal finds the shape, the frontend underlines what
/// a person is pointing at and says what opening does.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Overlay {
    /// A drag selection, as the two cells the drag started and ended on.
    pub selection: Option<(Cell, Cell)>,
    /// Underlines under a hovered link. `confirmed` is solid; the dotted
    /// look is a dashed run of quads, which is what `LinkUnderline` draws
    /// while the host is still asking whether the thing exists.
    pub link_underlines: Vec<LinkUnderline>,
    /// What to fill a selected cell with. The consumer owns this the way it
    /// owns the palette (Decision 0011); `TetherUI` uses accent at 0.12.
    pub selection_color: Rgba,
    /// What to underline a link with.
    pub link_color: Rgba,
}

/// A link drawn across one or more rows (Decision/0015: a wrapped link is
/// one link, and covers both rows).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LinkUnderline {
    pub span: CellSpan,
    /// Solid once the host says the thing exists; dotted while it is asking.
    pub confirmed: bool,
}

/// Everything one frame needs painted, in paint order.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct DrawList {
    /// The page. Everything else draws over it.
    pub background: Rgba,
    /// Cell backgrounds that differ from the page — runs with their own
    /// colour, inverse video, selections.
    pub rects: Vec<BgRect>,
    /// Glyphs, top-to-bottom, left-to-right within a row.
    pub texts: Vec<TextRun>,
    /// At most one caret, after the text so a block sits over its glyph.
    pub cursor: Option<CursorQuad>,
}

impl DrawList {
    pub fn is_empty(&self) -> bool {
        self.rects.is_empty() && self.texts.is_empty() && self.cursor.is_none()
    }
}

impl Default for Rgba {
    fn default() -> Self {
        Self::new(0.0, 0.0, 0.0, 1.0)
    }
}
