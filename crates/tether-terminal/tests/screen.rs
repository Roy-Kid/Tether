//! Recorded byte streams in, asserted screen state out.

use tether_terminal::{
    Cell, Color, CursorShape, NamedColor, Options, Palette, Rgb, ScreenSize, Scroll, Terminal,
    Underline,
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

/// One column hangs the engine's reflow: a wide character needs two, and
/// fitting scrollback into a grid that has one never terminates. The engine's
/// limit stops here rather than becoming a hang a consumer must know about.
///
/// Reachable from a frontend, not a theoretical input — dragging a window to
/// a sliver asks for exactly this.
#[test]
fn a_grid_too_narrow_for_the_engine_is_widened_to_one_it_can_reflow() {
    let mut term = fed("hello".as_bytes());

    term.resize(ScreenSize::new(1, 10));
    assert_eq!(term.size().columns, 2, "one column is widened to two");
    assert_eq!(term.size().rows, 10, "rows are left alone");

    term.resize(ScreenSize::new(0, 0));
    assert_eq!(term.size(), ScreenSize::new(2, 1), "an empty grid is not a grid");

    // The clamp is only a floor. Anything the engine can handle passes.
    term.resize(ScreenSize::new(3, 1));
    assert_eq!(term.size(), ScreenSize::new(3, 1));
}

/// A row must never claim more columns than it has.
///
/// Reflow onto a narrow screen can leave a wide character whose right-hand
/// spacer is gone, sitting next to an ordinary cell. Reporting it as two
/// columns wide overflows the row and sends a renderer past the end of its
/// own line — found by the fuzzer, at two columns claiming three.
#[test]
fn no_row_claims_more_columns_than_the_screen_has() {
    let mut term = Terminal::new(ScreenSize::new(40, 6));
    for _ in 0..12 {
        term.feed("中文字符中文字符中文字符\r\n".as_bytes());
    }

    for columns in [2u16, 3, 5, 8, 13, 21] {
        term.resize(ScreenSize::new(columns, 6));
        let screen = term.screen();

        for (index, row) in screen.rows().enumerate() {
            let claimed: usize = row.iter().map(|cell| cell.width as usize).sum();
            assert!(
                claimed <= columns as usize,
                "at {columns} columns, row {index} claimed {claimed}"
            );
        }
    }
}

/// Output that has scrolled off the top is still reachable.
///
/// Not a convenience: output a person cannot go back to is output they did
/// not receive.
#[test]
fn lines_that_scrolled_off_can_be_looked_at_again() {
    let mut term =
        Terminal::with_options(ScreenSize::new(20, 4), Options { scrollback_lines: 100 });
    for line in 0..20 {
        term.feed(format!("line-{line}\r\n").as_bytes());
    }

    // Only the last few are on screen.
    let live = term.screen().text();
    assert!(live.contains("line-19"), "the newest line is visible: {live}");
    assert!(!live.contains("line-00"), "the oldest is not: {live}");
    assert!(term.viewport().is_live());
    assert!(term.history_lines() >= 16, "history kept: {}", term.history_lines());

    term.scroll(Scroll::Oldest);
    let oldest = term.screen().text();
    assert!(oldest.contains("line-0"), "the oldest line is reachable: {oldest}");
    assert!(!term.viewport().is_live());
    assert_eq!(term.viewport().offset, term.history_lines(), "at the very top");

    term.scroll(Scroll::Live);
    assert!(term.viewport().is_live());
    assert_eq!(term.screen().text(), live, "back to exactly where it was");
}

/// Scrolling past either end stops there rather than running away, so a
/// wheel at the end of its travel is a no-op instead of a bug.
#[test]
fn the_viewport_is_clamped_at_both_ends() {
    let mut term =
        Terminal::with_options(ScreenSize::new(20, 4), Options { scrollback_lines: 100 });
    for line in 0..20 {
        term.feed(format!("line-{line}\r\n").as_bytes());
    }

    for _ in 0..50 {
        term.scroll(Scroll::PageUp);
    }
    assert_eq!(term.viewport().offset, term.history_lines(), "stops at the oldest line");

    for _ in 0..50 {
        term.scroll(Scroll::PageDown);
    }
    assert!(term.viewport().is_live(), "stops at the live screen");
}

/// A full-screen program's output is not scrollback, and the engine keeps
/// none for it — so the viewport cannot leave the live screen there.
#[test]
fn the_alternate_screen_has_no_history_to_scroll_into() {
    let mut term =
        Terminal::with_options(ScreenSize::new(20, 4), Options { scrollback_lines: 100 });
    for line in 0..20 {
        term.feed(format!("line-{line}\r\n").as_bytes());
    }
    assert!(term.history_lines() > 0);

    term.feed(b"\x1b[?1049h");
    assert!(term.screen().modes.alternate_screen);
    assert_eq!(term.history_lines(), 0, "no history on the alternate screen");

    term.scroll(Scroll::Oldest);
    assert!(term.viewport().is_live(), "there is nowhere to scroll to");

    // Leaving it puts the history back.
    term.feed(b"\x1b[?1049l");
    assert!(term.history_lines() > 0, "the history was waiting underneath");
}

/// What went past since the last frame, so a consumer holding its own view of
/// the scrollback can keep it still.
#[test]
fn changes_report_how_many_lines_went_past() {
    let mut term =
        Terminal::with_options(ScreenSize::new(20, 4), Options { scrollback_lines: 100 });
    let _ = term.take_changes();

    for line in 0..10 {
        term.feed(format!("line-{line}\r\n").as_bytes());
    }
    let changes = term.take_changes();
    assert!(changes.scrolled_lines > 0, "ten lines on a four-row screen scrolled some off");

    // Nothing new, nothing reported.
    assert_eq!(term.take_changes().scrolled_lines, 0);
}

/// Reading history while the far side is still talking must not yank the
/// viewport around.
///
/// A terminal that jumps to the bottom whenever a line arrives cannot be read
/// while anything is running, which is most of the time someone wants to read
/// it. Asserted rather than assumed: whether the engine holds the position is
/// its decision, and this is where we find out.
#[test]
fn new_output_does_not_move_a_viewport_that_is_reading_history() {
    let mut term =
        Terminal::with_options(ScreenSize::new(20, 4), Options { scrollback_lines: 100 });
    for line in 0..20 {
        term.feed(format!("line-{line:02}\r\n").as_bytes());
    }

    term.scroll(Scroll::Oldest);
    let reading = term.screen().text();
    assert!(reading.contains("line-00"), "parked at the top: {reading}");

    for line in 20..30 {
        term.feed(format!("line-{line:02}\r\n").as_bytes());
    }

    assert_eq!(term.screen().text(), reading, "the viewport stayed where it was put");
    assert!(!term.viewport().is_live(), "and is still reading history");

    // And coming back reaches the newest line, not where it used to be.
    term.scroll(Scroll::Live);
    assert!(term.screen().text().contains("line-29"), "the present is still the present");
}

/// A program asking what the background is gets the consumer's answer.
///
/// The one that matters in practice: with no reply, a program falls back to
/// assuming the terminal is dark and paints its own theme over every cell,
/// which no palette on the drawing side can undo.
#[test]
fn a_colour_query_is_answered_from_the_consumers_palette() {
    let mut term = terminal(20, 5);
    term.set_palette(Some(light()));

    term.feed(b"\x1b]11;?\x07");
    let reply = String::from_utf8(term.take_replies()).expect("a reply is text");
    assert!(reply.starts_with("\x1b]11;rgb:"), "answers the question that was asked: {reply:?}");
    assert!(reply.contains("fbfb/fbfb/fdfd"), "with the colour the consumer draws: {reply:?}");

    term.feed(b"\x1b]10;?\x07");
    let foreground = String::from_utf8(term.take_replies()).expect("a reply is text");
    assert!(foreground.starts_with("\x1b]10;rgb:1f1f/2121/2828"), "{foreground:?}");

    term.feed(b"\x1b]4;1;?\x07");
    let red = String::from_utf8(term.take_replies()).expect("a reply is text");
    assert!(red.contains("b3b3/1f1f/2b2b"), "the sixteen are the consumer's too: {red:?}");
}

/// A consumer that has not said what it draws with says nothing, rather than
/// having a colour invented for it (spec §12).
#[test]
fn a_colour_query_goes_unanswered_without_a_palette() {
    let mut term = terminal(20, 5);
    term.feed(b"\x1b]11;?\x07");
    assert!(term.take_replies().is_empty(), "no palette, no answer");

    // Nor for an index the consumer never gave us: the 6x6x6 cube is not
    // part of what a palette says.
    term.set_palette(Some(light()));
    term.feed(b"\x1b]4;123;?\x07");
    assert!(term.take_replies().is_empty(), "only what the consumer chose");
}

/// A light palette, the shape a frontend would hand down.
fn light() -> Palette {
    let grey = Rgb::new(0x80, 0x80, 0x80);
    Palette {
        foreground: Rgb::new(0x1f, 0x21, 0x28),
        background: Rgb::new(0xfb, 0xfb, 0xfd),
        cursor: Rgb::new(0x00, 0x7a, 0xff),
        ansi: [
            Rgb::new(0x00, 0x00, 0x00),
            Rgb::new(0xb3, 0x1f, 0x2b),
            Rgb::new(0x1a, 0x66, 0x33),
            Rgb::new(0x8c, 0x59, 0x0d),
            Rgb::new(0x1f, 0x4f, 0xd8),
            Rgb::new(0x7a, 0x2f, 0xa8),
            Rgb::new(0x00, 0x66, 0x80),
            grey,
            grey,
            Rgb::new(0xe5, 0x48, 0x4d),
            Rgb::new(0x1a, 0x80, 0x40),
            Rgb::new(0xf5, 0xa5, 0x24),
            Rgb::new(0x4c, 0x8d, 0xff),
            Rgb::new(0x8e, 0x4e, 0xc6),
            Rgb::new(0x00, 0xa2, 0xc7),
            Rgb::new(0xff, 0xff, 0xff),
        ],
    }
}
