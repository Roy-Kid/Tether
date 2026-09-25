//! Files where a session's shell is running.
//!
//! A file browser wants the same thing a second terminal does — the machine
//! the shell is on — and asks it a different question. The question is SFTP,
//! because SFTP is the protocol OpenSSH already answers on every host that
//! has a shell: `sftp-server` is started by `sshd` for a subsystem request,
//! or by us on this computer, and speaks the same bytes either way.
//!
//! The protocol is composed from `russh-sftp` and spoken
//! over a [`Transport`] — an ordered duplex byte stream, and nothing else. No
//! SSH or process type crosses into this crate, which is what lets one
//! implementation serve a remote session, an OpenSSH ControlMaster and this
//! machine, the same way `tether-tmux` does.
//!
//! Everything a server says is untrusted input (spec §18): names are data,
//! never paths to be interpreted locally, and a tree is removed without
//! following a link out of it.

mod entry;
mod error;
mod files;
mod path;
mod transfer;
mod transport;

pub use entry::{Entry, Kind};
pub use error::{Error, Result};
pub use files::Files;
pub use path::{join, name_of, parent_of};
pub use transport::Transport;
