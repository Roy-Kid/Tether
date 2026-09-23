//! A whole session's worth of operations, not just a byte stream.
//!
//! `terminal_stream` can only feed bytes. The paths that have actually broken
//! in this crate were the ones a byte stream cannot reach on its own: a
//! resize reflows the entire history, and both of the stress test's real
//! finds came from a screen resized to one column. So this target lets the
//! fuzzer interleave feeding, resizing and scrolling, with sizes it chooses —
//! including the degenerate ones a window dragged to a sliver produces.

#![no_main]

use arbitrary::Arbitrary;
use libfuzzer_sys::fuzz_target;
use tether_terminal::{Options, ScreenSize, Scroll, Terminal};

#[path = "../../crates/tether-terminal/tests/support/invariants.rs"]
#[allow(dead_code)]
mod invariants;

#[derive(Arbitrary, Debug)]
enum Step {
    Feed(Vec<u8>),
    Resize { columns: u8, rows: u8 },
    ScrollLines(i8),
    ScrollPageUp,
    ScrollPageDown,
    ScrollOldest,
    ScrollLive,
    ReadScreen,
}

#[derive(Arbitrary, Debug)]
struct Session {
    columns: u8,
    rows: u8,
    steps: Vec<Step>,
}

fuzz_target!(|session: Session| {
    // `u8` sizes, so the fuzzer spends its budget on behaviour rather than on
    // allocating a grid with sixty thousand columns — and zero stays
    // reachable, because it is what the degenerate cases are made of.
    let mut term = Terminal::with_options(
        ScreenSize::new(session.columns.into(), session.rows.into()),
        Options { scrollback_lines: 64 },
    );

    for (index, step) in session.steps.iter().enumerate() {
        match step {
            Step::Feed(bytes) => {
                term.feed(bytes);
                let _ = term.take_replies();
            }
            Step::Resize { columns, rows } => {
                term.resize(ScreenSize::new((*columns).into(), (*rows).into()));
            }
            Step::ScrollLines(lines) => term.scroll(Scroll::Lines((*lines).into())),
            Step::ScrollPageUp => term.scroll(Scroll::PageUp),
            Step::ScrollPageDown => term.scroll(Scroll::PageDown),
            Step::ScrollOldest => term.scroll(Scroll::Oldest),
            Step::ScrollLive => term.scroll(Scroll::Live),
            Step::ReadScreen => {
                let _ = term.screen();
            }
        }
        invariants::check(&mut term, &format!("step {index}: {step:?}"));
    }
});
