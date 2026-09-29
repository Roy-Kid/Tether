//! SSH: transport, authentication, host trust, channels and interactive shells.
//!
//! [`russh`] provides the protocol. This crate owns what a consumer sees:
//! domain types, the error model, host-trust policy, and the shape of an
//! interactive authentication exchange. `russh` types stop here (spec §8).
//!
//! Nothing in this crate knows about terminal grids, colours or cursors. It
//! moves bytes; what they mean is [`tether_terminal`]'s problem.
//!
//! The sequence SSH requires is carried by the types:
//!
//! ```text
//! Endpoint ──connect(verifier)──▶ Connection ──authenticate──▶ Session ──shell──▶ Shell
//! ```
//!
//! [`tether_terminal`]: https://docs.rs/tether-terminal

mod auth;
mod error;
mod host;
mod key;
mod session;
mod shell;

pub use auth::{Challenge, KEYBOARD_INTERACTIVE_IS_GENERIC, Method, Prompt, Prompter};
pub use error::SshError;
pub use host::{Endpoint, HostKey, HostVerifier, RejectAll, Verdict};
pub use key::{KeyDescription, KeyError, KeyUnlocker, PASSPHRASE_ATTEMPTS, PrivateKey};
pub use session::{Connection, Session, Step};
pub use shell::{Output, Shell, WindowSize};

/// Transport tuning, re-exported because a caller must be able to set
/// keepalives and timeouts and we have no better words for them than the
/// protocol's own.
pub use russh::client::Config;

/// Which SSH implementation answers, for diagnostics and about screens.
///
/// The engine is named, not hidden: a consumer reporting a protocol bug needs
/// to say which stack produced it. This is the only place `russh` is spoken
/// aloud on the public surface — its *types* still stop at this crate (§8).
pub fn backend_description() -> String {
    format!("russh {RUSSH_VERSION}")
}

/// `russh` exposes no version constant of its own, so the pin in the workspace
/// `Cargo.toml` is the authority and this mirrors it.
const RUSSH_VERSION: &str = "0.63";
