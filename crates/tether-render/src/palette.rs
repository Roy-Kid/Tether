//! Resolves the names the engine reports into colours a renderer draws.
//!
//! The engine deliberately reports `red`, not an RGB triple, because the
//! consumer owns the palette (spec §12, Decision 0011). This is that
//! ownership being exercised: one place decides what red means, and a light
//! theme is a different instance of this struct rather than a change
//! anywhere else.

use crate::draw::Rgba;
use crate::frame::{Name, Paint};

/// Sixteen ANSI slots plus the three the theme supplies.
#[derive(Debug, Clone, PartialEq)]
pub struct Palette {
    pub background: Rgba,
    pub foreground: Rgba,
    pub cursor: Rgba,
    /// Indices 0–7.
    pub normal: [Rgba; 8],
    /// Indices 8–15.
    pub bright: [Rgba; 8],
}

impl Palette {
    /// A dark theme with the usual sixteen. Values match
    /// `TetherUI.Palette.dark` so a window on either platform draws the same
    /// colours until a consumer supplies its own.
    pub fn dark() -> Self {
        Self {
            background: Rgba::new(0.07, 0.08, 0.10, 1.0),
            foreground: Rgba::new(0.87, 0.88, 0.90, 1.0),
            cursor: Rgba::new(0.55, 0.78, 0.96, 1.0),
            normal: [
                Rgba::new(0.16, 0.17, 0.20, 1.0),
                Rgba::new(0.90, 0.38, 0.40, 1.0),
                Rgba::new(0.47, 0.76, 0.45, 1.0),
                Rgba::new(0.90, 0.72, 0.36, 1.0),
                Rgba::new(0.40, 0.62, 0.90, 1.0),
                Rgba::new(0.76, 0.51, 0.85, 1.0),
                Rgba::new(0.36, 0.75, 0.77, 1.0),
                Rgba::new(0.78, 0.79, 0.81, 1.0),
            ],
            bright: [
                Rgba::new(0.34, 0.36, 0.40, 1.0),
                Rgba::new(0.96, 0.50, 0.51, 1.0),
                Rgba::new(0.60, 0.86, 0.57, 1.0),
                Rgba::new(0.96, 0.82, 0.48, 1.0),
                Rgba::new(0.53, 0.72, 0.96, 1.0),
                Rgba::new(0.85, 0.63, 0.93, 1.0),
                Rgba::new(0.48, 0.85, 0.87, 1.0),
                Rgba::new(0.94, 0.95, 0.96, 1.0),
            ],
        }
    }

    pub fn light() -> Self {
        Self {
            background: Rgba::new(0.985, 0.985, 0.99, 1.0),
            foreground: Rgba::new(0.12, 0.13, 0.16, 1.0),
            cursor: Rgba::new(0.0, 0.0, 1.0, 1.0),
            normal: [
                Rgba::new(0.0, 0.0, 0.0, 1.0),
                Rgba::new(0.7, 0.12, 0.17, 1.0),
                Rgba::new(0.1, 0.4, 0.2, 1.0),
                Rgba::new(0.55, 0.35, 0.05, 1.0),
                Rgba::new(0.0, 0.0, 1.0, 1.0),
                Rgba::new(0.5, 0.0, 0.5, 1.0),
                Rgba::new(0.0, 0.4, 0.5, 1.0),
                Rgba::new(0.5, 0.5, 0.5, 1.0),
            ],
            bright: [
                Rgba::new(0.5, 0.5, 0.5, 1.0),
                Rgba::new(1.0, 0.0, 0.0, 1.0),
                Rgba::new(0.1, 0.5, 0.25, 1.0),
                Rgba::new(1.0, 0.5, 0.0, 1.0),
                Rgba::new(0.0, 0.0, 1.0, 1.0),
                Rgba::new(0.5, 0.0, 0.5, 1.0),
                Rgba::new(0.0, 0.5, 0.5, 1.0),
                Rgba::new(1.0, 1.0, 1.0, 1.0),
            ],
        }
    }

    /// Which palette a setting and a system appearance add up to.
    ///
    /// One place, because two would drift: the surface draws with this and
    /// the session tells the far side about it, and a screen drawn light
    /// while the far side was told "dark" is worse than either mistake alone.
    pub fn chosen(setting: &str, system_is_dark: bool) -> Self {
        let dark = setting == "dark" || (setting == "system" && system_is_dark);
        if dark {
            Self::dark()
        } else {
            Self::light()
        }
    }

    pub fn resolve(&self, paint: Paint) -> Rgba {
        match paint {
            Paint::Named(name) => self.named(name),
            Paint::Indexed(index) => self.indexed(index),
            Paint::Rgb { red, green, blue } => Rgba::new(
                red as f32 / 255.0,
                green as f32 / 255.0,
                blue as f32 / 255.0,
                1.0,
            ),
        }
    }

    fn named(&self, name: Name) -> Rgba {
        match name {
            Name::Black => self.normal[0],
            Name::Red => self.normal[1],
            Name::Green => self.normal[2],
            Name::Yellow => self.normal[3],
            Name::Blue => self.normal[4],
            Name::Magenta => self.normal[5],
            Name::Cyan => self.normal[6],
            Name::White => self.normal[7],
            Name::BrightBlack => self.bright[0],
            Name::BrightRed => self.bright[1],
            Name::BrightGreen => self.bright[2],
            Name::BrightYellow => self.bright[3],
            Name::BrightBlue => self.bright[4],
            Name::BrightMagenta => self.bright[5],
            Name::BrightCyan => self.bright[6],
            Name::BrightWhite => self.bright[7],
            Name::Foreground => self.foreground,
            Name::Background => self.background,
            Name::Cursor => self.cursor,
        }
    }

    /// The standard 256-colour layout: sixteen named, then a 6×6×6 cube, then
    /// twenty-four greys. Computed rather than tabulated — the cube is
    /// genuinely a formula, and the levels are not evenly spaced, which is
    /// why the first step is 0 and the rest are 55 apart.
    fn indexed(&self, index: u8) -> Rgba {
        match index {
            0..=7 => self.normal[index as usize],
            8..=15 => self.bright[index as usize - 8],
            16..=231 => {
                let value = index as i32 - 16;
                let level = |step: i32| {
                    if step == 0 {
                        0.0
                    } else {
                        (55 + step * 40) as f32 / 255.0
                    }
                };
                Rgba::new(
                    level(value / 36),
                    level((value / 6) % 6),
                    level(value % 6),
                    1.0,
                )
            }
            _ => {
                let grey = (8 + (index as i32 - 232) * 10) as f32 / 255.0;
                Rgba::new(grey, grey, grey, 1.0)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn named_colours_come_from_the_theme() {
        let dark = Palette::dark();
        assert_eq!(dark.resolve(Paint::Named(Name::Red)), dark.normal[1]);
        assert_eq!(dark.resolve(Paint::Named(Name::Background)), dark.background);
        assert_eq!(dark.resolve(Paint::Named(Name::Cursor)), dark.cursor);
    }

    #[test]
    fn indexed_resolves_the_cube_and_greys() {
        let palette = Palette::dark();
        // 16 is the first cube entry: (0, 0, 0).
        assert_eq!(
            palette.resolve(Paint::Indexed(16)),
            Rgba::new(0.0, 0.0, 0.0, 1.0)
        );
        // 231 is the last cube entry: (255, 255, 255).
        assert_eq!(
            palette.resolve(Paint::Indexed(231)),
            Rgba::new(1.0, 1.0, 1.0, 1.0)
        );
        // 232 is the first grey: 8/255.
        let first_grey = 8.0 / 255.0;
        assert_eq!(
            palette.resolve(Paint::Indexed(232)),
            Rgba::new(first_grey, first_grey, first_grey, 1.0)
        );
    }

    #[test]
    fn rgb_is_taken_as_is() {
        let palette = Palette::dark();
        assert_eq!(
            palette.resolve(Paint::Rgb { red: 255, green: 128, blue: 0 }),
            Rgba::new(1.0, 128.0 / 255.0, 0.0, 1.0)
        );
    }

    #[test]
    fn chosen_picks_one_place() {
        assert_eq!(Palette::chosen("dark", false), Palette::dark());
        assert_eq!(Palette::chosen("light", true), Palette::light());
        assert_eq!(Palette::chosen("system", true), Palette::dark());
        assert_eq!(Palette::chosen("system", false), Palette::light());
    }
}
