//! The damage contract under coverage-guided input.
//!
//! Damage is part of the contract, not an optimisation (spec §12): a frontend
//! that redraws only what it was told changed must end up with the screen the
//! engine has. A span the engine forgets to report leaves stale text on a
//! real terminal, and no test that reads whole screens would ever see it.
//!
//! `corpus.rs` asks this of eight recorded workloads. This asks it of input
//! nobody thought of.

#![no_main]

use libfuzzer_sys::fuzz_target;
use tether_terminal::{Options, ScreenSize, Terminal};

// Shared with the unit tests by path rather than copied: two drifting
// definitions of "the damage was enough" would be worse than one.
#[path = "../../crates/tether-terminal/tests/support/mirror.rs"]
#[allow(dead_code)]
mod mirror;

fuzz_target!(|data: &[u8]| {
    let Some((&first, stream)) = data.split_first() else { return };

    let mut term =
        Terminal::with_options(ScreenSize::new(80, 24), Options { scrollback_lines: 64 });
    let mut consumer = mirror::Mirror::new(&term.screen());

    let chunk = usize::from(first).max(1);
    for (index, piece) in stream.chunks(chunk).enumerate() {
        term.feed(piece);
        let changes = term.take_changes();
        let screen = term.screen();
        consumer.apply(&changes, &screen);

        if let Some(disagreement) = consumer.disagreement(&screen) {
            panic!("damage was not enough at chunk {index}\n{disagreement}");
        }
    }
});
