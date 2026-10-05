//! The boundary's own arithmetic.
//!
//! These types exist to be marshalled, and marshalling has no opinions: if a
//! run's column count is wrong, a frontend lays the next run on top of the
//! last one and nothing in Rust ever notices. So the invariants a renderer
//! depends on are asserted here rather than left to be discovered on screen.

use tether_core::terminal::{Options, ScreenSize, Terminal};
use tether_ffi::{CellColor, ColorName, FrameUpdate, ScreenFrame};

fn frame(columns: u16, rows: u16, bytes: &[u8]) -> ScreenFrame {
    let mut terminal =
        Terminal::with_options(ScreenSize::new(columns, rows), Options { scrollback_lines: 64 });
    terminal.feed(bytes);
    ScreenFrame::of(&terminal.screen(), terminal.title().to_owned())
}

#[test]
fn one_character_does_not_copy_the_other_rows() {
    let mut terminal =
        Terminal::with_options(ScreenSize::new(40, 8), Options { scrollback_lines: 16 });
    let _ = terminal.take_frame_delta();
    terminal.feed(b"x");
    match FrameUpdate::from_delta(&terminal.take_frame_delta()) {
        FrameUpdate::Rows { rows, .. } => {
            assert_eq!(rows.len(), 1);
            assert_eq!(rows[0].row, 0);
            assert!(rows[0].line.runs.iter().any(|run| run.text.contains('x')));
        }
        other => panic!("expected row damage, got {other:?}"),
    }
    assert!(matches!(
        FrameUpdate::from_delta(&terminal.take_frame_delta()),
        FrameUpdate::Idle { .. }
    ));
}

/// A frontend places each run at a column by adding up the ones before it. If
/// the sum could exceed the width, it would draw off the end of the row.
#[test]
fn no_row_of_runs_covers_more_columns_than_the_screen_has() {
    for columns in [2u16, 3, 5, 8, 20, 80] {
        let frame =
            frame(columns, 8, "中文字符 abc \u{1F468}\u{200D}\u{1F469} e\u{0301}".as_bytes());

        for (index, row) in frame.lines.iter().enumerate() {
            let covered: u32 = row.runs.iter().map(|run| run.columns).sum();
            assert!(
                covered <= columns as u32,
                "at {columns} columns, row {index} covered {covered}"
            );
        }
    }
}

/// Every run must cover at least one column, or a frontend advancing by
/// `columns` would place the next run on top of this one for ever.
#[test]
fn every_run_covers_at_least_one_column() {
    let frame = frame(40, 4, b"\x1b[31mred\x1b[0m plain \x1b[1mbold\x1b[0m");

    for row in &frame.lines {
        for run in &row.runs {
            assert!(run.columns >= 1, "a run covering nothing: {run:?}");
            assert!(!run.text.is_empty(), "a run with no text: {run:?}");
        }
    }
}

/// The whole reason the boundary is runs rather than cells: a row of plain
/// text must not cross as eighty separate strings.
#[test]
fn text_in_one_style_collapses_into_one_run() {
    let frame = frame(40, 2, b"hello world");
    let first = &frame.lines[0];

    assert_eq!(first.runs.len(), 1, "one style should be one run: {:?}", first.runs);
    assert_eq!(first.runs[0].columns, 40, "the run covers the whole row");
    assert!(first.runs[0].text.starts_with("hello world"));
}

/// And it must not collapse text that looks different, or colour would be
/// lost on the way out.
#[test]
fn a_change_of_style_starts_a_new_run() {
    let frame = frame(40, 2, b"\x1b[31mred\x1b[32mgreen\x1b[0m");
    let runs = &frame.lines[0].runs;

    assert!(runs.len() >= 3, "red, green and the blank remainder: {runs:?}");
    assert_eq!(runs[0].text, "red");
    assert_eq!(runs[0].columns, 3);
    assert!(matches!(runs[0].style.foreground, CellColor::Named { name: ColorName::Red }));

    assert_eq!(runs[1].text, "green");
    assert_eq!(runs[1].columns, 5);
    assert!(matches!(runs[1].style.foreground, CellColor::Named { name: ColorName::Green }));
}

/// A frontend laying out a grid advances by columns, not by characters, and
/// the two genuinely differ: a wide character is one grapheme over two
/// columns. That is why `columns` is carried beside `text` instead of being
/// recomputed from it.
#[test]
fn a_run_is_measured_in_columns_not_characters() {
    // Narrow enough that the wide character is the only thing on the row.
    let exact = frame(2, 2, "中".as_bytes());
    let run = &exact.lines[0].runs[0];

    assert_eq!(run.text, "中");
    assert_eq!(run.columns, 2);
    assert_ne!(
        run.text.chars().count() as u32,
        run.columns,
        "counting characters would misplace everything after this run"
    );
}

/// A run is drawn as one string, and a string is spaced to the grid by a
/// single number — so every character in it has to cost the same number of
/// columns. A wide character merged in with narrow ones is how a line of
/// Chinese slides out from under the cursor standing on it.
#[test]
fn a_change_of_width_starts_a_new_run() {
    let frame = frame(40, 2, "ab中文cd".as_bytes());
    let runs = &frame.lines[0].runs;

    let shape: Vec<(&str, u32, usize)> =
        runs.iter().map(|run| (run.text.as_str(), run.columns, run.text.chars().count())).collect();

    for (text, columns, characters) in &shape {
        assert_eq!(
            *columns % *characters as u32,
            0,
            "{text:?} covers {columns} columns as {characters} characters, so there is no \
             whole number of columns per character to space it by: {shape:?}"
        );
    }

    assert_eq!(runs[0].text, "ab");
    assert_eq!(runs[1].text, "中文");
    assert_eq!(runs[1].columns, 4, "two wide characters, two columns each");
    assert!(runs[2].text.starts_with("cd"), "narrow text resumes: {:?}", runs[2].text);
}

/// The frame carries the size it was built from, so a frontend never has to
/// ask two sources and reconcile them.
#[test]
fn the_frame_agrees_with_itself_about_its_size() {
    let frame = frame(30, 9, b"anything");

    assert_eq!(frame.columns, 30);
    assert_eq!(frame.rows, 9);
    assert_eq!(frame.lines.len(), 9, "one entry per row, always");
    assert!(frame.cursor_row < frame.rows);
    assert!(frame.cursor_column <= frame.columns);
}

/// A title the far side never set is empty, not absent — a frontend showing
/// it has one less case to write.
#[test]
fn the_title_is_whatever_the_far_side_set() {
    assert_eq!(frame(20, 3, b"no title here").title, "");
    assert_eq!(frame(20, 3, b"\x1b]0;deploy\x07").title, "deploy");
}

/// Reflow onto a narrow grid is where the boundary's arithmetic breaks if it
/// is going to: the engine can leave a wide character without the column it
/// reserved.
#[test]
fn narrowing_onto_a_grid_too_small_for_wide_text_keeps_the_rows_honest() {
    let mut terminal =
        Terminal::with_options(ScreenSize::new(40, 6), Options { scrollback_lines: 64 });
    for _ in 0..10 {
        terminal.feed("中文字符中文字符\r\n".as_bytes());
    }

    for columns in [2u16, 3, 4, 7] {
        terminal.resize(ScreenSize::new(columns, 6));
        let frame = ScreenFrame::of(&terminal.screen(), terminal.title().to_owned());

        assert_eq!(frame.columns, columns as u32);
        for (index, row) in frame.lines.iter().enumerate() {
            let covered: u32 = row.runs.iter().map(|run| run.columns).sum();
            assert!(
                covered <= columns as u32,
                "at {columns} columns, row {index} covered {covered}"
            );
        }
    }
}

/// A frame says where it was taken from, so a renderer can draw a scrollbar
/// that agrees with the rows it was handed.
#[test]
fn a_frame_reports_its_position_in_the_scrollback() {
    let mut terminal =
        Terminal::with_options(ScreenSize::new(20, 4), Options { scrollback_lines: 100 });
    for line in 0..20 {
        terminal.feed(format!("line-{line:02}\r\n").as_bytes());
    }

    let live = ScreenFrame::of(&terminal.screen(), String::new());
    assert_eq!(live.viewport_offset, 0, "live");
    assert!(live.history_lines > 0, "with history behind it");

    terminal.scroll(tether_core::terminal::Scroll::Oldest);
    let back = ScreenFrame::of(&terminal.screen(), String::new());
    assert_eq!(back.viewport_offset, back.history_lines, "parked at the oldest line");
    assert_ne!(back.lines, live.lines, "and showing different rows");
}
