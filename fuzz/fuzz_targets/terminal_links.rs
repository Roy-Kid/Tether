//! Pointing at remote text, coverage-guided.
//!
//! Two parsers read what the far side printed without drawing it: the link
//! finder, when a person points at the screen, and the working-directory
//! scanner, on every byte. Both are remote input (spec §18). The screen is
//! narrow so that wrapping — the finder's hardest case — happens constantly,
//! and every cell is pointed at, because a crash only at column 37 is still
//! a crash.

#![no_main]

use libfuzzer_sys::fuzz_target;
use tether_terminal::{LinkTarget, Options, Position, ScreenSize, Terminal};

fuzz_target!(|data: &[u8]| {
    let Some((&first, stream)) = data.split_first() else { return };
    let size = ScreenSize::new(u16::from(first % 30) + 2, 6);
    let mut term = Terminal::with_options(size, Options { scrollback_lines: 16 });
    for piece in stream.chunks(usize::from(first).max(1)) {
        term.feed(piece);
        let _ = term.take_replies();
    }

    if let Some(directory) = term.working_directory() {
        assert!(directory.starts_with('/'), "a relative directory: {directory:?}");
        assert!(!directory.chars().any(char::is_control), "{directory:?}");
    }

    for row in 0..size.rows {
        for column in 0..size.columns {
            let Some(link) = term.link_at(Position::new(row, column)) else { continue };
            assert!(!link.text.is_empty());
            assert!(!link.spans.is_empty());
            assert!(
                link.spans
                    .iter()
                    .any(|span| span.row == row && span.start <= column && column < span.end),
                "the link does not cover the point it was found at: {link:?} at {row},{column}"
            );
            if let LinkTarget::Path { path, .. } = &link.target {
                assert!(!path.is_empty() && !path.contains(char::is_whitespace), "{path:?}");
            }
            for span in &link.spans {
                assert!(span.row < size.rows && span.start < span.end && span.end <= size.columns);
            }
        }
    }
});
