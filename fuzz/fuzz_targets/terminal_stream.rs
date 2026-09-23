//! Remote bytes into the terminal, coverage-guided.
//!
//! Everything a terminal reads was chosen by whatever is on the far end of
//! someone else's network, so "defensive parsing of everything remote" is a
//! security requirement rather than a robustness one (spec §18), and §19 asks
//! for `cargo-fuzz` on everything that reads remote bytes.
//!
//! The stream is fed in chunks whose sizes come from the input itself, so the
//! fuzzer can also find the bugs that only appear when a sequence is split —
//! which is what a network does to every stream, constantly.

#![no_main]

use libfuzzer_sys::fuzz_target;
use tether_terminal::{Options, ScreenSize, Terminal};

// The invariant checks are the ones the unit tests use. Shared by path rather
// than copied: two drifting definitions of "the screen is valid" would be
// worse than one.
#[path = "../../crates/tether-terminal/tests/support/invariants.rs"]
#[allow(dead_code)]
mod invariants;

fuzz_target!(|data: &[u8]| {
    let Some((&first, stream)) = data.split_first() else { return };

    // A short scrollback: with the default ten thousand lines a fuzzer spends
    // its time in the allocator instead of the parser.
    let mut term =
        Terminal::with_options(ScreenSize::new(80, 24), Options { scrollback_lines: 64 });

    let chunk = usize::from(first).max(1);
    let pieces = stream.len().div_ceil(chunk);
    // Every chunk is fed, but the invariants are checked on a sample of them.
    // Reading a whole screen costs more than parsing the bytes that changed
    // it, and a target that spends its budget re-reading an unchanged grid is
    // a target running at twenty executions a second. The last chunk is
    // always checked, so no input ends unexamined.
    let every = pieces.div_ceil(64).max(1);

    for (index, piece) in stream.chunks(chunk).enumerate() {
        term.feed(piece);
        let _ = term.take_replies();
        if index % every == 0 || index + 1 == pieces {
            invariants::check(&mut term, &format!("chunk {index} of {chunk} bytes"));
        }
    }
});
