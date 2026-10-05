//! One measurement of the monospaced font, reused for every cell.
//!
//! Ported from `TetherUI.FontMetrics`. The cell is a whole number of points
//! wide so that a column lands on the same place every time, and the font is
//! then *spaced into* that cell rather than trusted to fill it. Those are two
//! different numbers: a face can advance 8.04pt at 13pt, and a grid built on
//! 8 that draws text at 8.04 is a grid whose eightieth column is three
//! characters out.

/// Geometry of one monospaced cell, and the spacing that lands runs on it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FontMetrics {
    /// The point size the advances were measured at.
    pub size: f32,
    /// Integer cell width. Columns are this far apart, always.
    pub cell_width: f32,
    /// Row pitch, rounded up so a line box always fits its glyphs.
    pub line_height: f32,
    /// What one column costs the font, before it is spaced to `cell_width`.
    narrow_advance: f32,
    /// The same for a character that covers two columns. Measured rather
    /// than doubled: CJK comes from a fallback face whose advance is its own,
    /// and assuming twice the Latin one misplaces every character after the
    /// first.
    wide_advance: f32,
}

impl FontMetrics {
    /// Builds metrics from advances already measured.
    ///
    /// `narrow_advance` and `wide_advance` are the font's own advances;
    /// `cell_width` is the integer column pitch the grid uses. Keeping them
    /// separate is the whole point — see [`FontMetrics::tracking`].
    pub fn from_advances(
        size: f32,
        narrow_advance: f32,
        wide_advance: f32,
        line_height: f32,
    ) -> Self {
        // Nearest, not up: rounding up added most of a point per column at
        // 13pt, and the text then had to be stretched by that much to keep up.
        let cell_width = narrow_advance.round().max(1.0);
        Self { size, cell_width, line_height: line_height.max(1.0), narrow_advance, wide_advance }
    }

    /// The font's own advance for a one-column and a two-column character.
    pub fn advances(&self) -> (f32, f32) {
        (self.narrow_advance, self.wide_advance)
    }

    /// The extra advance that makes `characters` characters cover exactly
    /// `cells` columns.
    ///
    /// A run carries one cell width throughout — the boundary is drawn where
    /// it changes — so this is a division rather than a per-character
    /// measurement on the drawing path.
    pub fn tracking(&self, cells: u32, characters: usize) -> f32 {
        if characters == 0 {
            return 0.0;
        }
        let columns = cells as f32 / characters as f32;
        let advance = if columns > 1.5 { self.wide_advance } else { self.narrow_advance };
        columns * self.cell_width - advance
    }

    /// The drawn width of `characters` glyphs covering `cells` columns,
    /// after tracking has been applied. The grid law is that this equals
    /// `cells * cell_width` within a point.
    pub fn tracked_width(&self, cells: u32, characters: usize) -> f32 {
        if characters == 0 {
            return 0.0;
        }
        let columns = cells as f32 / characters as f32;
        let advance = if columns > 1.5 { self.wide_advance } else { self.narrow_advance };
        // Each glyph advances `advance` plus `tracking`; `tracking` was
        // solved so the total lands on `cells * cell_width`.
        characters as f32 * (advance + self.tracking(cells, characters))
    }

    /// How many cells of this font fit in `width`, which is also the size a
    /// terminal is told it is. Floor, not nearest: a fraction of a cell is
    /// not a cell, and rounding up is how the last column was drawn past the
    /// clip and never seen.
    pub fn columns_fitting(&self, width: f32) -> u16 {
        (width / self.cell_width).floor().clamp(1.0, 1000.0) as u16
    }

    pub fn rows_fitting(&self, height: f32) -> u16 {
        (height / self.line_height).floor().clamp(1.0, 500.0) as u16
    }

    /// Left edge of `column`, and the width `columns` columns cover.
    ///
    /// Integer arithmetic on the column pitch: a run's box is exactly
    /// `columns * cell_width` wide, so the next run starts where this one
    /// ends and the eightieth column is where the cursor is.
    pub fn cell_x(&self, column: u32) -> f32 {
        column as f32 * self.cell_width
    }

    pub fn cell_y(&self, row: u32) -> f32 {
        row as f32 * self.line_height
    }

    pub fn cells_width(&self, columns: u32) -> f32 {
        columns as f32 * self.cell_width
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// SF Mono at 13pt advances about 8.04; the grid must still be whole.
    fn thirteen() -> FontMetrics {
        FontMetrics::from_advances(13.0, 8.04, 16.08, 15.6)
    }

    #[test]
    fn cells_are_whole() {
        for size in [10.0f32, 13.0, 18.0, 24.0] {
            let metrics = FontMetrics::from_advances(size, size * 0.62, size * 1.24, size * 1.2);
            assert_eq!(metrics.cell_width, metrics.cell_width.round());
            assert!(metrics.cell_width >= 1.0);
        }
        assert_eq!(thirteen().cell_width, 8.0);
    }

    #[test]
    fn narrow_runs_keep_the_grid() {
        let metrics = thirteen();
        let drawn = metrics.tracked_width(80, 80);
        let grid = metrics.cell_width * 80.0;
        assert!((drawn - grid).abs() <= 1.0, "eighty columns drew {drawn} against a {grid} grid");
    }

    #[test]
    fn wide_runs_keep_the_grid() {
        let metrics = thirteen();
        // Twenty CJK characters cover forty columns.
        let drawn = metrics.tracked_width(40, 20);
        let grid = metrics.cell_width * 40.0;
        assert!(
            (drawn - grid).abs() <= 1.0,
            "twenty wide characters drew {drawn} against a {grid} grid"
        );
    }

    #[test]
    fn fitting_does_not_overflow() {
        let metrics = thirteen();
        for width in [0.0f32, 1.0, 7.0, 8.0, 8.5, 100.0, 1100.0, 1100.4] {
            let columns = metrics.columns_fitting(width);
            let used = columns as f32 * metrics.cell_width;
            assert!(
                used <= width || columns == 1,
                "{columns} columns of {} into {width}",
                metrics.cell_width
            );
        }
        assert_eq!(metrics.columns_fitting(0.0), 1);
        assert_eq!(metrics.columns_fitting(10_000.0), 1000);
    }

    #[test]
    fn rows_fitting_is_capped() {
        let metrics = thirteen();
        assert_eq!(metrics.rows_fitting(0.0), 1);
        assert_eq!(metrics.rows_fitting(10_000.0), 500);
    }

    #[test]
    fn empty_runs_cost_nothing() {
        let metrics = thirteen();
        assert_eq!(metrics.tracking(0, 0), 0.0);
        assert_eq!(metrics.tracked_width(80, 0), 0.0);
    }
}
