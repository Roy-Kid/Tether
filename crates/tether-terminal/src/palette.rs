//! The colours a consumer draws with, for the questions the far side asks.
//!
//! The engine reports colour *names* and never invents an RGB value: what
//! `red` looks like belongs to whoever is drawing (spec §12). That rule is
//! about the screen, and this is not the screen — it is the answer to
//! `OSC 11 ; ? BEL`, "what is your background?", which only the thing that
//! draws can answer.
//!
//! Leaving it unanswered is not neutral. A program that asks and hears
//! nothing falls back to the convention that a terminal is dark, and then
//! paints its own dark theme over every cell — so a light window ends up
//! black, and no palette on the consumer's side can undo it, because those
//! cells now carry explicit colours.
//!
//! A consumer that says nothing keeps today's behaviour: the queries are
//! dropped.

/// One colour, as the far side will be told it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rgb {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
}

impl Rgb {
    pub const fn new(red: u8, green: u8, blue: u8) -> Self {
        Self { red, green, blue }
    }

    /// Whether this colour reads as a dark one.
    ///
    /// Rec. 601 luma, the same rule a terminal uses to decide whether it is
    /// a "dark" or "light" terminal. Here so that a consumer does not have
    /// to reimplement it to fill in `COLORFGBG`.
    pub fn is_dark(self) -> bool {
        let luma = 0.299 * f32::from(self.red)
            + 0.587 * f32::from(self.green)
            + 0.114 * f32::from(self.blue);
        luma < 128.0
    }
}

/// What a consumer draws with.
///
/// Only what a consumer actually chose: the sixteen ANSI colours and the
/// three that have no number. The 6×6×6 cube and the greys above them are
/// not in here, and a query for one goes unanswered rather than being
/// answered with a value nobody picked.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Palette {
    pub foreground: Rgb,
    pub background: Rgb,
    pub cursor: Rgb,
    /// The sixteen ANSI colours: eight normal, then eight bright.
    pub ansi: [Rgb; 16],
}

/// Where the named colours sit in the index space a query uses.
const FOREGROUND: usize = 256;
const BACKGROUND: usize = 257;
const CURSOR: usize = 258;

impl Palette {
    /// The colour a query is asking about, if this palette has one.
    pub(crate) fn at(&self, index: usize) -> Option<Rgb> {
        match index {
            0..=15 => Some(self.ansi[index]),
            FOREGROUND => Some(self.foreground),
            BACKGROUND => Some(self.background),
            CURSOR => Some(self.cursor),
            _ => None,
        }
    }
}
