//! Adversarial byte streams against the invariants a consumer relies on.
//!
//! A terminal reads bytes chosen by whatever is on the far end of someone
//! else's network. "It does not panic" is the floor, not the contract: a
//! cursor or a damage span outside the screen would have a renderer index out
//! of bounds, and that is reachable from remote input.
//!
//! Deterministic by construction — a seeded generator, not a clock — so a
//! failure here is a failure anyone can reproduce from the seed alone. The
//! same invariants are checked against recorded real workloads in
//! `corpus.rs`, and against coverage-guided input by `fuzz/`, which needs a
//! nightly toolchain.

mod support;

use support::invariants;
use tether_terminal::{Options, ScreenSize, Terminal};

/// xorshift64*. A test that needs random bytes does not need a dependency.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, bound: usize) -> usize {
        (self.next() % bound as u64) as usize
    }
}

/// Fragments that make a random stream look like a terminal stream rather
/// than noise: purely random bytes almost never form a valid CSI sequence, so
/// a generator without these would fuzz the "invalid input" path only.
const FRAGMENTS: &[&[u8]] = &[
    b"\x1b[",
    b"\x1b]",
    b"\x1b[?1049h",
    b"\x1b[?1049l",
    b"\x1b[2J",
    b"\x1b[H",
    b"\x1b[999;999H",
    b"\x1b[38;2;",
    b"\x1b[6n",
    b"\x1b[",
    b";",
    b"m",
    b"~",
    b"\x07",
    b"\x08",
    b"\r\n",
    b"\x1b[999S",
    b"\x1b[999T",
    b"\x1b[999L",
    b"\x1b[999M",
    b"\x1b#8",
    b"\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9",
    b"\xe4\xb8\xad",
    b"\xff\xfe",
    b"e\xcc\x81",
];

fn torture(seed: u64) {
    let mut rng = Rng(seed | 1);
    // A short scrollback on purpose: this test resizes constantly, and every
    // resize reflows the whole history. With the default ten thousand lines it
    // is measuring the allocator, not the parser.
    let mut term =
        Terminal::with_options(ScreenSize::new(40, 12), Options { scrollback_lines: 64 });

    for step in 0..400 {
        let mut chunk = Vec::new();
        for _ in 0..rng.below(6) + 1 {
            if rng.below(3) == 0 {
                chunk.extend_from_slice(FRAGMENTS[rng.below(FRAGMENTS.len())]);
            } else {
                chunk.push((rng.next() & 0xff) as u8);
            }
        }

        // Split the chunk at an arbitrary point, so escape sequences and UTF-8
        // scalars are routinely cut in half the way a network cuts them.
        let cut = rng.below(chunk.len() + 1);
        term.feed(&chunk[..cut]);
        term.feed(&chunk[cut..]);

        let _ = term.take_replies();

        if rng.below(25) == 0 {
            // Zero and one are in range on purpose. They are what a window
            // dragged to a sliver produces, and both of this test's real
            // finds came from them: a one-column grid hung the engine's
            // reflow, and a narrow resize left a wide character whose spacer
            // was gone claiming a column the row did not have.
            term.resize(ScreenSize::new(rng.below(200) as u16, rng.below(80) as u16));
        }

        invariants::check(&mut term, &format!("seed {seed} step {step}"));
    }
}

#[test]
fn adversarial_streams_keep_the_screen_within_its_own_bounds() {
    for seed in 1..=32u64 {
        torture(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15));
    }
}

/// Every prefix of a stream must be safe to stop at: a connection can drop
/// anywhere, including halfway through an escape sequence.
#[test]
fn every_prefix_of_a_stream_leaves_a_usable_terminal() {
    let stream: Vec<u8> = FRAGMENTS.concat();

    for cut in 0..=stream.len() {
        let mut term =
            Terminal::with_options(ScreenSize::new(20, 6), Options { scrollback_lines: 64 });
        term.feed(&stream[..cut]);
        invariants::check(&mut term, &format!("prefix of {cut} bytes"));
    }
}
