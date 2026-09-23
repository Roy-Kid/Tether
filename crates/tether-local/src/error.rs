//! What can go wrong between "run a shell" and a running shell.

/// A failure on this machine, in our words.
///
/// `portable-pty` reports everything as `anyhow::Error`. That type stops
/// here: an `anyhow` chain on the public surface would make every caller
/// depend on which backend opened the terminal, which is the coupling §8
/// exists to prevent. The backend's sentence survives as `cause`, because a
/// person debugging a permissions problem needs it (spec §18).
#[derive(Debug, Clone, thiserror::Error, PartialEq, Eq)]
pub enum LocalError {
    /// The kernel would not give us a pseudo-terminal pair.
    #[error("could not open a pseudo-terminal: {cause}")]
    NoTerminal { cause: String },

    /// The program does not exist, is not executable, or the working
    /// directory is not somewhere we may go.
    #[error("could not start {program}: {cause}")]
    NotStarted { program: String, cause: String },

    /// The shell exited, or was never started on this platform.
    #[error("the shell is no longer running")]
    Ended,

    #[error("could not write to the shell: {cause}")]
    Write { cause: String },

    #[error("could not resize the terminal: {cause}")]
    Resize { cause: String },

    /// This platform does not let an application start one.
    ///
    /// iOS is the case that matters: there is no `fork`/`exec` outside the
    /// sandbox, so a local shell is not a feature that is merely missing —
    /// it is one the system does not offer. Saying so plainly is better than
    /// a permission error a person would try to fix.
    #[error("this platform does not allow an application to start a shell")]
    Unsupported,
}
