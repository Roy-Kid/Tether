//! Terminal engine boundary.
//!
//! Bytes arrive, screen state and incremental damage come out; semantic input
//! goes the other way. The engine itself is [`alacritty_terminal`] — this crate
//! exists to keep its types out of Tether's public surface and to own the
//! damage contract, not to reimplement it (spec §6, §12).
//!
//! This crate is headless and must stay that way: no network, no GPU, no
//! windowing. See [`NO_SSH_DEPENDENCY`].

mod damage;
mod screen;
mod size;
mod style;
mod terminal;

pub use damage::{Changes, RowSpan, ScreenDamage};
pub use screen::{Cell, Cursor, CursorShape, Modes, Screen};
pub use size::{Position, ScreenSize};
pub use style::{Color, NamedColor, Style, Underline};
pub use terminal::Terminal;

/// The byte-stream boundary in executable form.
///
/// `tether-terminal` must never reach a network. Anything that feeds it —
/// an SSH shell, a tmux pane, a recording, a serial port — is the caller's
/// concern. The guarantee is checked by `cargo tree` in CI and asserted here
/// so the reason travels with the code (spec §3, §8).
pub const NO_SSH_DEPENDENCY: &str =
    "tether-terminal links no SSH symbol; producers feed it bytes";
