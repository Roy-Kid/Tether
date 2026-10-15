//! The screen as the consumer was last told it, so damage cannot fall short.
//!
//! The engine reports what `input` wrote as the span between where the cursor
//! was at the last `damage()` and where it is now, and a cursor does not
//! always travel in a line. `fuzz/terminal_damage` has found that shortfall
//! more than once — a zero-width joiner that changed the cell before the
//! cursor, and text that wraps on a bottom row a scroll region stops above,
//! where the line feed has nowhere to go and the row starts over in place
//! (`alacritty_terminal` 0.26, `Term::wrapline` → `linefeed`). Each time a
//! frontend that redrew only what it was told left stale cells behind
//! (spec §12).
//!
//! Compared rather than predicted. Finding the next case one fuzzer run at a
//! time is a contract that holds until the next run; comparing the cells the
//! consumer was given with the cells there now holds whatever the engine
//! missed. The engine's own damage still comes first — it also names the
//! cursor's cells, which no cell comparison can see.

use alacritty_terminal::grid::{Dimensions, Grid};
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::Cell;

use crate::damage::RowSpan;

/// The visible rows as of the last comparison, in viewport order.
#[derive(Debug, Default)]
pub(crate) struct Shadow {
    rows: Vec<Vec<Cell>>,
}

impl Shadow {
    /// The span of each visible row that differs from the last comparison,
    /// and keeps what is there now. Only differing cells are copied, so an
    /// unchanged screen costs a comparison and nothing else.
    ///
    /// A screen of another shape starts again from blank; that only happens
    /// on a resize, which is already a full redraw.
    pub(crate) fn changed(&mut self, grid: &Grid<Cell>) -> Vec<RowSpan> {
        let (rows, columns) = (grid.screen_lines(), grid.columns());
        if self.rows.len() != rows || self.rows.iter().any(|row| row.len() != columns) {
            self.rows = vec![vec![Cell::default(); columns]; rows];
        }
        let offset = grid.display_offset() as i32;

        let mut spans = Vec::new();
        for (row, kept) in self.rows.iter_mut().enumerate() {
            let line = &grid[Line(row as i32 - offset)];
            let mut differs: Option<(usize, usize)> = None;
            for (column, was) in kept.iter_mut().enumerate() {
                let now = &line[Column(column)];
                if was != now {
                    *was = now.clone();
                    differs = Some(differs.map_or((column, column), |(first, _)| (first, column)));
                }
            }
            if let Some((first, last)) = differs {
                spans.push(RowSpan {
                    row: narrow(row),
                    first_column: narrow(first),
                    last_column: narrow(last),
                });
            }
        }
        spans
    }
}

/// A grid index as a [`RowSpan`] coordinate. The grid is sized from a
/// [`ScreenSize`](crate::ScreenSize), so it always fits.
fn narrow(index: usize) -> u16 {
    u16::try_from(index).unwrap_or(u16::MAX)
}
