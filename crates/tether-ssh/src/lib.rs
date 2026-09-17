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
mod session;
mod shell;

pub use auth::{Challenge, Method, Prompt, Prompter, KEYBOARD_INTERACTIVE_IS_GENERIC};
pub use error::SshError;
pub use host::{Endpoint, HostKey, HostVerifier, RejectAll, Verdict};
pub use session::{Connection, Session, Step};
pub use shell::{Output, Shell, WindowSize};

/// Transport tuning, re-exported because a caller must be able to set
/// keepalives and timeouts and we have no better words for them than the
/// protocol's own.
pub use russh::client::Config;
