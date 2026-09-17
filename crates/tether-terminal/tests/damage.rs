//! Damage is part of the contract, not an optimisation (spec §12).
//!
//! The claim these tests defend is narrow and checkable: a small mutation must
//! not cost a consumer a whole-screen diff. Asserting only "something changed"
//! would pass against an engine that reported `Full` for every keystroke,
//! which is exactly the failure worth preventing.

use tether_terminal::{Changes, ScreenDamage, ScreenSize, Terminal};

fn terminal() -> Terminal {
    let mut term = Terminal::new(ScreenSize::new(80, 24));
    // A new terminal reports a full first paint, which is correct and not what
    // any of these tests are measuring. Drain it.
    assert_eq!(term.take_changes().screen, ScreenDamage::Full);
    term
}

fn spans(changes: &Changes) -> Vec<(u16, u16, u16)> {
    match &changes.screen {
        ScreenDamage::Rows(rows) => {
            rows.iter().map(|r| (r.row, r.first_column, r.last_column)).collect()
        }
        other => panic!("expected row damage, got {other:?}"),
    }
}

#[test]
fn an_untouched_terminal_reports_nothing() {
    let mut term = terminal();
    assert!(term.take_changes().is_empty());
}

/// One character typed on one row must damage one row — and a span of two
/// cells, not the width of the screen.
///
/// Two cells rather than one because the cursor moved: where it was and where
/// it now is both have to be redrawn. That is the engine's contract as much as
/// ours, and a test that demanded one cell would be asserting a terminal that
/// leaves a cursor behind.
#[test]
fn a_single_character_damages_one_narrow_span() {
    let mut term = terminal();
    term.feed(b"x");

    assert_eq!(spans(&term.take_changes()), vec![(0, 0, 1)]);
}

#[test]
fn an_edit_far_down_the_screen_damages_only_that_row() {
    let mut term = terminal();
    term.feed(b"\x1b[10;5Hedit");

    let changes = term.take_changes();
    let damaged: Vec<u16> = match &changes.screen {
        ScreenDamage::Rows(rows) => rows.iter().map(|r| r.row).collect(),
        other => panic!("expected row damage, got {other:?}"),
    };

    // Row 0 as well as row 9: the cursor left row 0, so the cell it vacated
    // has to be repainted. Two rows out of twenty-four is the claim being
    // defended — not "only the row you typed on", which no terminal can offer.
    assert_eq!(damaged, vec![0, 9], "the edited row and the one the cursor left");
    let edited = match &changes.screen {
        ScreenDamage::Rows(rows) => *rows.iter().find(|r| r.row == 9).expect("row 9"),
        _ => unreachable!(),
    };
    assert!(
        edited.first_column >= 4 && edited.last_column <= 8,
        "expected a span around columns 4..8, got {edited:?}"
    );
}

#[test]
fn damage_is_taken_not_repeated() {
    let mut term = terminal();
    term.feed(b"x");

    assert!(!term.take_changes().is_empty());
    assert!(term.take_changes().is_empty());
}

/// Reflow can move every line, so there is nothing honest to report but
/// everything.
#[test]
fn a_resize_invalidates_the_whole_screen() {
    let mut term = terminal();
    term.resize(ScreenSize::new(100, 30));

    assert_eq!(term.take_changes().screen, ScreenDamage::Full);
    assert_eq!(term.size(), ScreenSize::new(100, 30));
}

#[test]
fn a_cursor_move_is_reported_even_with_no_text_change() {
    let mut term = terminal();
    term.feed(b"\x1b[5;5H");

    let changes = term.take_changes();
    let cursor = changes.cursor.expect("the cursor moved");
    assert_eq!((cursor.position.row, cursor.position.column), (4, 4));
}

#[test]
fn a_mode_change_is_reported_once() {
    let mut term = terminal();
    term.feed(b"\x1b[?1049h");

    let modes = term.take_changes().modes.expect("entering the alternate screen is news");
    assert!(modes.alternate_screen);

    term.feed(b"\x1b[?1049h");
    assert_eq!(term.take_changes().modes, None, "an unchanged mode is not news");
}

/// A full-screen redraw is allowed to say "everything", but the common case —
/// a prompt redrawn after a keystroke — must not.
#[test]
fn a_prompt_redraw_does_not_invalidate_the_screen() {
    let mut term = terminal();
    term.feed(b"$ ls -la");
    let _ = term.take_changes();

    // Backspace over a character and retype, the way line editing does.
    term.feed(b"\x08 \x08x");

    let changes = term.take_changes();
    match &changes.screen {
        ScreenDamage::Rows(rows) => {
            assert_eq!(rows.len(), 1, "one row touched, got {rows:?}");
        }
        other => panic!("line editing must not invalidate the screen, got {other:?}"),
    }
}
