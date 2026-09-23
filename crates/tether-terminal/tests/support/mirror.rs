//! A consumer that believes the damage contract, kept honest against one
//! that does not.
//!
//! Damage is part of the contract, not an optimisation (spec §12). The claim
//! is that applying the reported spans is *enough* — that a frontend which
//! never re-reads an undamaged cell still draws the same screen. A missing
//! span would leave stale text on a real terminal, and nothing in a test that
//! only reads whole screens would ever notice.

use tether_terminal::{Cell, Changes, Screen, ScreenDamage};

pub struct Mirror {
    rows: Vec<Vec<Cell>>,
    columns: u16,
}

impl Mirror {
    /// Starts from a full read, which is what a frontend does on its first
    /// frame.
    pub fn new(screen: &Screen) -> Self {
        Self { rows: screen.rows().map(<[Cell]>::to_vec).collect(), columns: screen.size.columns }
    }

    /// Applies one frame's worth of damage — and nothing else.
    pub fn apply(&mut self, changes: &Changes, screen: &Screen) {
        let resized =
            screen.size.columns != self.columns || screen.rows().count() != self.rows.len();

        match &changes.screen {
            ScreenDamage::None if !resized => {}
            ScreenDamage::Rows(spans) if !resized => {
                for (index, row) in screen.rows().enumerate() {
                    let marked: Vec<&_> =
                        spans.iter().filter(|span| span.row as usize == index).collect();
                    if marked.is_empty() {
                        continue;
                    }
                    let mut columns = vec![false; self.columns as usize];
                    for span in marked {
                        for column in span.first_column..=span.last_column {
                            if let Some(slot) = columns.get_mut(column as usize) {
                                *slot = true;
                            }
                        }
                    }
                    self.rows[index] = merge(&self.rows[index], row, &mut columns);
                }
            }
            // `Full` says to redraw everything, and so does a resize: a
            // renderer has no choice, and neither does this.
            _ => {
                self.rows = screen.rows().map(<[Cell]>::to_vec).collect();
                self.columns = screen.size.columns;
            }
        }
    }

    /// The first row where believing the damage was not enough.
    pub fn disagreement(&self, screen: &Screen) -> Option<String> {
        for (index, row) in screen.rows().enumerate() {
            let mine = self.rows.get(index).map(Vec::as_slice).unwrap_or(&[]);
            if mine == row {
                continue;
            }
            // The first differing *cell*, not just the row's text: a cell
            // whose style or width is wrong reads identically as text, and
            // "these two identical strings differ" helps nobody.
            let at = (0..mine.len().max(row.len()))
                .find(|index| mine.get(*index) != row.get(*index))
                .unwrap_or_default();
            return Some(format!(
                "row {index}, cell {at}\n  drawn from damage: {:?}\n    …at that cell: {:?}\n                   actually on screen: {:?}\n    …at that cell: {:?}",
                text(mine),
                mine.get(at),
                text(row),
                row.get(at),
            ));
        }
        None
    }
}

fn text(row: &[Cell]) -> String {
    row.iter().map(|cell| cell.text.as_str()).collect::<String>().trim_end().to_string()
}

/// Rebuilds a row: damaged columns from the new state, the rest from what the
/// consumer already had.
///
/// The marked columns are first widened to cell boundaries, because a cell is
/// the unit a renderer can draw. Half of a double-width character is not
/// something either side can hold, so a span that lands inside one covers the
/// whole of it — which is what a correct frontend does anyway.
fn merge(old: &[Cell], new: &[Cell], columns: &mut [bool]) -> Vec<Cell> {
    let width = columns.len();
    let old_starts = starts(old, width);
    let new_starts = starts(new, width);
    let boundary = |column: usize| {
        column >= width || (old_starts[column].is_some() && new_starts[column].is_some())
    };

    let mut column = 0;
    while column < width {
        if !columns[column] {
            column += 1;
            continue;
        }
        let mut first = column;
        let mut last = column;
        while last + 1 < width && columns[last + 1] {
            last += 1;
        }
        column = last + 1;

        while first > 0 && !boundary(first) {
            first -= 1;
        }
        while !boundary(last + 1) {
            last += 1;
        }
        for slot in columns.iter_mut().take(last + 1).skip(first) {
            *slot = true;
        }
    }

    let mut merged = Vec::with_capacity(new.len());
    let mut column = 0;
    while column < width {
        let source = if columns[column] { (new, &new_starts) } else { (old, &old_starts) };
        match source.1[column] {
            Some(index) => {
                let cell = source.0[index].clone();
                column += usize::from(cell.width).max(1);
                merged.push(cell);
            }
            // No cell begins at this column in the source: the engine
            // dropped a spacer, and the row genuinely covers fewer columns
            // than the grid has. Inventing a blank here would give the
            // consumer a row a cell longer than the one it is mirroring —
            // measured by `fuzz/terminal_damage`, which reported a
            // disagreement between two rows whose text was identical.
            None => column += 1,
        }
    }
    merged
}

/// Which cell, if any, begins at each column.
fn starts(row: &[Cell], columns: usize) -> Vec<Option<usize>> {
    let mut map = vec![None; columns];
    let mut column = 0;
    for (index, cell) in row.iter().enumerate() {
        if column >= columns {
            break;
        }
        map[column] = Some(index);
        column += usize::from(cell.width).max(1);
    }
    map
}
