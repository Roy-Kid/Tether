//! What must be true of a screen no matter what bytes produced it.
//!
//! "It does not panic" is the floor, not the contract: a cursor or a damage
//! span outside the screen would have a renderer index out of bounds, and
//! that is reachable from remote input.

use tether_terminal::{ScreenDamage, Terminal};

/// Checks the screen against its own contract, and consumes the damage.
///
/// `where_from` names the input that produced this state — a seed and a step,
/// or a recording and an offset — so a failure is reproducible from the
/// message alone.
pub fn check(term: &mut Terminal, where_from: &str) {
    let size = term.size();

    let changes = term.take_changes();
    if let ScreenDamage::Rows(spans) = &changes.screen {
        for span in spans {
            assert!(
                span.row < size.rows,
                "{where_from}: damage at row {} of {} rows",
                span.row,
                size.rows
            );
            assert!(span.first_column <= span.last_column, "{where_from}: inverted span {span:?}");
            assert!(
                span.last_column < size.columns,
                "{where_from}: damage at column {} of {} columns",
                span.last_column,
                size.columns
            );
        }
    }

    let screen = term.screen();
    assert_eq!(screen.size, size);
    assert_eq!(screen.rows().count(), size.rows as usize, "{where_from}: row count drifted");

    assert!(
        screen.cursor.position.row < size.rows,
        "{where_from}: cursor at row {} of {} rows",
        screen.cursor.position.row,
        size.rows
    );
    assert!(
        screen.cursor.position.column <= size.columns,
        "{where_from}: cursor at column {} of {} columns",
        screen.cursor.position.column,
        size.columns
    );

    for (index, row) in screen.rows().enumerate() {
        let width: usize = row.iter().map(|cell| cell.width as usize).sum();
        assert!(
            width <= size.columns as usize,
            "{where_from}: row {index} claims {width} columns of {}",
            size.columns
        );
        for cell in row {
            assert!(!cell.text.is_empty(), "{where_from}: a cell with no text");
        }
    }
}
