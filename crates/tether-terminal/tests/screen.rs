//! Recorded byte streams in, asserted screen state out.

use tether_terminal::{
    Cell, Color, CursorShape, NamedColor, ScreenDamage, ScreenSize, Terminal, Underline,
};

fn terminal(columns: u16, rows: u16) -> Terminal {
    Terminal::new(ScreenSize::new(columns, rows))
}

fn fed(bytes: &[u8]) -> Terminal {
    let mut term = terminal(20, 5);
    term.feed(bytes);
    term
}

#[test]
fn plain_text_lands_on_the_first_row() {
    let term = fed(b"hello");
    assert_eq!(term.screen().row_text(0), "hello");
}

/// A network delivers whatever sizes it likes. An escape sequence cut in half
/// by a packet boundary must resume, not be printed as garbage — this is the
/// single most common way a terminal wrapper breaks in the field.
#[test]
fn an_escape_sequence_split_across_feeds_still_applies() {
    let mut term = terminal(20, 5);
    term.feed(b"\x1b[3");
    term.feed(b"1mred");

    let screen = term.screen();
    assert_eq!(screen.row_text(0), "red");
    assert_eq!(screen.row(0).unwrap()[0].style.foreground, Color::Named(NamedColor::Red));
}

/// The same hazard one level down: a multi-byte scalar split mid-sequence.
#[test]
fn a_utf8_scalar_split_across_feeds_is_reassembled() {
    let snowman = "☃".as_bytes();
    let (first, second) = snowman.split_at(1);

    let mut term = terminal(20, 5);
    term.feed(first);
    term.feed(second);

    assert_eq!(term.screen().row_text(0), "☃");
}

/// Bytes, scalars, graphemes, glyphs and cells are five different things
/// (spec §12). `é` written as `e` + U+0301 is two scalars, one grapheme, and
/// one cell — and a consumer must receive it whole.
#[test]
fn a_combining_mark_stays_in_one_cell() {
    let term = fed("e\u{0301}".as_bytes());
    let screen = term.screen();

    assert_eq!(screen.row_text(0), "e\u{0301}");
    let cells: Vec<&Cell> = screen.row(0).unwrap().iter().take(1).collect();
    assert_eq!(cells[0].text.chars().count(), 2, "two scalars");
    assert_eq!(cells[0].width, 1, "one column");
}

/// A wide character is one cell that covers two columns — not two cells, and
/// not one cell the consumer has to guess the width of.
#[test]
fn a_wide_character_is_one_cell_of_width_two() {
    let term = fed("中".as_bytes());
    let screen = term.screen();
    let row = screen.row(0).unwrap();

    assert_eq!(row[0].text, "中");
    assert_eq!(row[0].width, 2);
    // The column it covers is not reported as a cell of its own: the engine's
    // spacer is bookkeeping, not content.
    assert_eq!(row[1].text, " ", "the next reported cell is the one after it");
    assert_eq!(screen.row_text(0), "中");
}

/// An emoji joined by zero-width joiners is one grapheme. Splitting it would
/// turn a family into four people.
#[test]
fn a_zero_width_joiner_sequence_stays_in_one_cell() {
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    let term = fed(family.as_bytes());
    let row_text = term.screen().row_text(0);

    assert_eq!(row_text.chars().filter(|c| *c == '\u{200D}').count(), 2, "joiners survived");
    assert_eq!(row_text, family);
}

#[test]
fn text_attributes_cross_the_boundary_as_our_own_types() {
    let term = fed(b"\x1b[1;3;4;9;38;2;10;20;30mstyled");
    let screen = term.screen();
    let style = screen.row(0).unwrap()[0].style;

    assert!(style.bold);
    assert!(style.italic);
    assert!(style.strikethrough);
    assert_eq!(style.underline, Underline::Single);
    assert_eq!(style.foreground, Color::Rgb { red: 10, green: 20, blue: 30 });
}

#[test]
fn the_cursor_can_be_moved_and_hidden() {
    let mut term = terminal(20, 5);
    term.feed(b"\x1b[3;7H");

    let cursor = term.screen().cursor;
    // The escape is one-based; a consumer's grid is not.
    assert_eq!(cursor.position.row, 2);
    assert_eq!(cursor.position.column, 6);
    assert!(cursor.visible);

    term.feed(b"\x1b[?25l");
    let hidden = term.screen().cursor;
    assert!(!hidden.visible);
    assert_eq!(hidden.shape, CursorShape::Hidden);
}

#[test]
fn modes_a_frontend_must_act_on_are_reported() {
    let mut term = terminal(20, 5);
    assert!(!term.screen().modes.alternate_screen);

    term.feed(b"\x1b[?1049h\x1b[?2004h\x1b[?1h");
    let modes = term.screen().modes;

    assert!(modes.alternate_screen, "scrollback must not be shown");
    assert!(modes.bracketed_paste, "a paste must be distinguishable from typing");
    assert!(modes.application_cursor_keys, "arrow keys encode differently now");
}

#[test]
fn a_title_change_is_reported_once() {
    let mut term = terminal(20, 5);
    term.feed(b"\x1b]0;deploy\x07");

    let changes = term.take_changes();
    assert_eq!(changes.title.as_deref(), Some("deploy"));
    assert_eq!(term.title(), "deploy");

    term.feed(b"x");
    assert_eq!(term.take_changes().title, None, "an unchanged title is not news");
}

/// A program that asks where the cursor is will wait forever if the answer is
/// dropped. These replies belong back on the same channel the bytes came from.
#[test]
fn a_device_status_report_produces_a_reply_to_send_back() {
    let mut term = terminal(20, 5);
    term.feed(b"\x1b[3;7H\x1b[6n");

    let reply = term.take_replies();
    assert_eq!(reply, b"\x1b[3;7R");
    assert!(term.take_replies().is_empty(), "replies are taken, not repeated");
}

#[test]
fn the_bell_is_reported_once() {
    let mut term = terminal(20, 5);
    term.feed(b"\x07");

    assert!(term.take_changes().bell);
    assert!(!term.take_changes().bell);
}
