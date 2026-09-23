//! What a terminal session reads from.
//!
//! §8 draws the byte-stream boundary and then says what it is for: "an SSH
//! interactive shell is one producer. tmux panes and recordings are others."
//! This is that sentence made into a type.
//!
//! The consequence is the point. A session over a shell on the far side of
//! the world and a session over a shell on this machine are not two kinds of
//! session with a shared base — they are one [`TerminalSession`], reading
//! from two producers. Nothing above this line has a branch for which.
//!
//! [`TerminalSession`]: crate::TerminalSession

use std::future::Future;

use tether_terminal::ScreenSize;

/// Something a producer produced.
///
/// Bytes, not text: a shell emits whatever it likes, including invalid UTF-8
/// mid-sequence, and deciding what that means belongs to the terminal.
///
/// One byte arm, not two. A pseudo-terminal — local or remote — gives the
/// program on the other end a single stream, so stdout and stderr are already
/// interleaved in the order they were written. A producer that keeps them
/// apart merges them here rather than making every consumer invent an order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Output {
    Bytes(Vec<u8>),
    /// The program ended with this status. More output may still arrive
    /// after it, which is why it is an event rather than the end.
    Exited(u32),
}

/// Why a producer stopped being able to do what was asked.
///
/// A sentence, not a code. Which backend failed and what number it used are
/// diagnostic context inside `cause`, never the shape a consumer matches on:
/// swapping SSH stacks, or moving from a remote shell to a local one, must
/// not be a breaking change for anything above (spec §18).
#[derive(Debug, Clone, thiserror::Error, PartialEq, Eq)]
#[error("{cause}")]
pub struct ProducerError {
    pub cause: String,
}

impl ProducerError {
    pub fn new(cause: impl std::fmt::Display) -> Self {
        Self { cause: cause.to_string() }
    }
}

/// A bidirectional byte stream with a terminal's shape: it can be written to,
/// it can be told how big the screen is, and it ends.
///
/// Statically dispatched rather than `dyn`. A producer is chosen once, when a
/// session is created, and never changes — so the indirection would buy
/// nothing and cost an allocation on the path that runs per chunk of output.
///
/// Every method takes `&mut self`, which is what makes "two writes are never
/// in flight" a fact the compiler checks rather than a rule a comment asks
/// for.
pub trait Producer: Send + 'static {
    /// Sends bytes to the program's input.
    fn write(&mut self, bytes: Vec<u8>) -> impl Future<Output = Result<(), ProducerError>> + Send;

    /// Tells the far end the screen changed size, so full-screen programs
    /// redraw and line editing wraps in the right place.
    fn resize(
        &mut self,
        size: ScreenSize,
    ) -> impl Future<Output = Result<(), ProducerError>> + Send;

    /// The next thing produced, or `None` once the stream is over.
    ///
    /// Must be cancel-safe: the pump parks on this inside a `select!`
    /// alongside the command queue, and a keystroke arriving mid-read must
    /// not cost the bytes that were already on their way.
    fn next_output(&mut self) -> impl Future<Output = Option<Output>> + Send;

    /// Ends the stream and releases whatever holds it open.
    fn close(self) -> impl Future<Output = ()> + Send;
}

// MARK: - The two producers this workspace ships

impl Producer for tether_ssh::Shell {
    async fn write(&mut self, bytes: Vec<u8>) -> Result<(), ProducerError> {
        tether_ssh::Shell::write(self, bytes).await.map_err(ProducerError::new)
    }

    async fn resize(&mut self, size: ScreenSize) -> Result<(), ProducerError> {
        let window = tether_ssh::WindowSize::new(size.columns as u32, size.rows as u32);
        tether_ssh::Shell::resize(self, window).await.map_err(ProducerError::new)
    }

    async fn next_output(&mut self) -> Option<Output> {
        match tether_ssh::Shell::next_output(self).await? {
            // SSH is the one producer that reports the two streams apart, so
            // it is the one that has to put them back together. A PTY gave
            // the far side a single stream; keeping the halves separate here
            // would reorder what the person sees.
            tether_ssh::Output::Stdout(bytes) | tether_ssh::Output::Stderr(bytes) => {
                Some(Output::Bytes(bytes))
            }
            tether_ssh::Output::Exited(status) => Some(Output::Exited(status)),
        }
    }

    async fn close(self) {
        // Nowhere to report a failure to: the session is ending either way,
        // and a server that will not acknowledge a close has already stopped
        // being reachable.
        let _ = tether_ssh::Shell::close(self).await;
    }
}

impl Producer for tether_local::Shell {
    async fn write(&mut self, bytes: Vec<u8>) -> Result<(), ProducerError> {
        tether_local::Shell::write(self, bytes).await.map_err(ProducerError::new)
    }

    async fn resize(&mut self, size: ScreenSize) -> Result<(), ProducerError> {
        let window = tether_local::WindowSize::new(size.columns, size.rows);
        // An `ioctl`, so it does not await anything — but the trait is async
        // because the remote producer's resize crosses a network, and a
        // shape that fits only the cheap case is the wrong shape.
        tether_local::Shell::resize(self, window).map_err(ProducerError::new)
    }

    async fn next_output(&mut self) -> Option<Output> {
        match tether_local::Shell::next_output(self).await? {
            tether_local::Output::Bytes(bytes) => Some(Output::Bytes(bytes)),
            tether_local::Output::Exited(status) => Some(Output::Exited(status)),
        }
    }

    async fn close(self) {
        tether_local::Shell::close(self);
    }
}
