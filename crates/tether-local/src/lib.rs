//! A shell on this machine, on a pseudo-terminal.
//!
//! The local counterpart to [`tether_ssh`]. Same job, same shape, different
//! side of the network: open a terminal, start a shell on it, move bytes.
//! §8 calls an SSH interactive shell "one producer" and says there are
//! others — this is one of the others, and it is deliberately not a special
//! case of the SSH one.
//!
//! Nothing here knows about grids, colours or cursors, and nothing here links
//! an SSH symbol. A consumer that wants a local terminal takes this crate and
//! [`tether_terminal`] without a protocol stack coming along (spec §3).
//!
//! ```no_run
//! # use tether_local::{Command, Shell, WindowSize, Output};
//! # async fn example() -> Result<(), Box<dyn std::error::Error>> {
//! let mut shell = Shell::open(Command::login_shell(), WindowSize::new(120, 40))?;
//!
//! shell.write("uname -sm\n").await?;
//! while let Some(output) = shell.next_output().await {
//!     if let Output::Bytes(bytes) = output {
//!         print!("{}", String::from_utf8_lossy(&bytes));
//!     }
//! }
//! # Ok(()) }
//! ```
//!
//! [`tether_ssh`]: https://docs.rs/tether-ssh
//! [`tether_terminal`]: https://docs.rs/tether-terminal

mod command;
mod error;
mod process;
#[cfg(not(target_os = "ios"))]
mod shell;
#[cfg(target_os = "ios")]
#[path = "shell_unavailable.rs"]
mod shell;

pub use command::Command;
pub use error::LocalError;
pub use process::{Capture, Stream};
pub use shell::{Output, Shell, WindowSize, process_current_directory as current_directory};

/// Whether this platform lets an application start a shell.
///
/// A question rather than a failure, so a consumer can leave the feature out
/// of its interface instead of offering one that always refuses. iOS is the
/// case this exists for.
pub fn is_available() -> bool {
    !cfg!(target_os = "ios")
}

/// Which pseudo-terminal implementation answers, for diagnostics and about
/// screens.
///
/// Named, not hidden: a consumer reporting a terminal bug needs to say which
/// stack produced it. This is the only place `portable-pty` is spoken aloud
/// on the public surface — its *types* still stop at this crate (§8).
pub fn backend_description() -> String {
    if cfg!(target_os = "ios") {
        "no pseudo-terminal".to_owned()
    } else {
        format!("portable-pty {PORTABLE_PTY_VERSION}")
    }
}

/// `portable-pty` exposes no version constant of its own, so the pin in the
/// workspace `Cargo.toml` is the authority and this mirrors it.
const PORTABLE_PTY_VERSION: &str = "0.9";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_backend_is_named() {
        if cfg!(target_os = "ios") {
            assert_eq!(backend_description(), "no pseudo-terminal");
        } else {
            assert!(backend_description().starts_with("portable-pty"));
        }
    }

    #[test]
    fn availability_follows_the_platform() {
        assert_eq!(is_available(), !cfg!(target_os = "ios"));
    }
}
