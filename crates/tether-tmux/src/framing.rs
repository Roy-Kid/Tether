//! Where a tmux control stream stops being bytes and starts being events.
//!
//! Everything here reads data a remote machine chose, so the limits are the
//! point: a control stream that never sends a newline, a `%layout-change`
//! nested a thousand deep, or a command reply that never ends are all things
//! a server can say, and none of them may become unbounded memory or
//! unbounded recursion on this side (spec §18).
//!
//! Separated from the driver so the limits can be tested — and fuzzed —
//! without a transport, a runtime or a tmux.

use std::collections::VecDeque;

use tmuxctl::{Event, Parser};

use crate::{Error, Result};

/// One line of control output may not exceed this before a newline arrives.
const LINE_LIMIT: usize = 4 * 1024 * 1024;
/// One command's reply block may not exceed this in total.
const BLOCK_LIMIT: usize = 8 * 1024 * 1024;
/// How deep a layout description may nest.
const LAYOUT_NESTING_LIMIT: usize = 64;

/// Bytes in, protocol events out, with the limits applied.
pub(crate) struct Framing {
    parser: Parser,
    buffer: Vec<u8>,
    events: VecDeque<Event>,
    block_bytes: usize,
}

impl Framing {
    pub(crate) fn new() -> Self {
        Self { parser: Parser::new(), buffer: Vec::new(), events: VecDeque::new(), block_bytes: 0 }
    }

    /// Adds whatever arrived. Err means the stream broke a limit and the
    /// connection is not worth continuing.
    pub(crate) fn push(&mut self, bytes: &[u8]) -> Result<()> {
        self.buffer.extend_from_slice(bytes);
        if self.buffer.len() > LINE_LIMIT {
            return Err(Error("tmux protocol line exceeds limit".into()));
        }

        while let Some(end) = self.buffer.iter().position(|b| *b == b'\n') {
            let mut line: Vec<_> = self.buffer.drain(..=end).collect();
            line.pop();

            // Bound recursive layout parsing before passing remote data
            // upstream: tmuxctl walks the layout tree, and the depth of that
            // walk is chosen by the server.
            if line.starts_with(b"%layout-change ")
                && line.iter().filter(|b| matches!(b, b'[' | b'{')).count() > LAYOUT_NESTING_LIMIT
            {
                return Err(Error("tmux layout exceeds nesting limit".into()));
            }

            self.block_bytes += line.len();
            if self.block_bytes > BLOCK_LIMIT {
                return Err(Error("tmux response exceeds limit".into()));
            }
            if let Some(event) = self.parser.push(&line) {
                self.block_bytes = 0;
                self.events.push_back(event);
            }
        }
        Ok(())
    }

    pub(crate) fn next(&mut self) -> Option<Event> {
        self.events.pop_front()
    }
}

/// Runs the framing over one input and reports how many events came out.
///
/// For `fuzz/`, which asks whether a remote stream can panic this or make it
/// grow without bound. A count rather than the events themselves: `tmuxctl`'s
/// types stop inside this crate (spec §8), and a fuzz target is not a reason
/// to let them out.
#[cfg(feature = "fuzzing")]
#[doc(hidden)]
pub fn frame_for_fuzzing(chunks: &[&[u8]]) -> Result<usize> {
    let mut framing = Framing::new();
    let mut count = 0;
    for chunk in chunks {
        framing.push(chunk)?;
        while framing.next().is_some() {
            count += 1;
        }
    }
    Ok(count)
}
