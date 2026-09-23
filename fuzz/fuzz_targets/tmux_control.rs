//! The tmux control stream's framing, which is ours.
//!
//! `tmuxctl` parses the protocol; the limits around it do not come from
//! upstream. A control stream that never sends a newline, a `%layout-change`
//! nested past what a recursive walk can take, and a reply block that never
//! ends are all things a server can say — and a server is remote, so none of
//! them may become unbounded memory on this side (spec §18).
//!
//! The chunk boundaries come from the input, because a transport delivers the
//! stream in pieces it chose and a limit checked per-read is not the same as
//! a limit checked per-line.

#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Some((&first, stream)) = data.split_first() else { return };

    let chunk = usize::from(first).max(1);
    let pieces: Vec<&[u8]> = stream.chunks(chunk).collect();

    // An error is a normal outcome: it is the limits doing their job. What
    // this target is looking for is a panic, a hang, or memory that grows
    // past what the limits claim to allow.
    let _ = tether_tmux::frame_for_fuzzing(&pieces);
});
