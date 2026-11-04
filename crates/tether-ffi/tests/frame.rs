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
