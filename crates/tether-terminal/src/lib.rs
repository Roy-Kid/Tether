//! Terminal engine boundary.
//!
//! Bytes arrive, screen state and incremental damage come out; semantic input
//! goes the other way. The engine itself is [`alacritty_terminal`] — this crate
//! exists to keep its types out of Tether's public surface and to own the
//! damage contract, not to reimplement it (spec §6, §12).
//!
//! This crate is headless and must stay that way: no network, no GPU, no
//! windowing. See [`NO_SSH_DEPENDENCY`].

/// The byte-stream boundary in executable form.
///
/// `tether-terminal` must never reach a network. Anything that feeds it —
/// an SSH shell, a tmux pane, a recording, a serial port — is the caller's
/// concern. The guarantee is checked by `cargo tree` in CI and asserted here
/// so the reason travels with the code (spec §3, §8).
pub const NO_SSH_DEPENDENCY: &str =
    "tether-terminal links no SSH symbol; producers feed it bytes";

/// Version of the upstream engine this boundary wraps.
///
/// Phase 2 replaces this with the real surface: feed, resize, screen state,
/// damage, input encoding.
pub fn engine_description() -> &'static str {
    concat!("alacritty_terminal ", env!("CARGO_PKG_VERSION"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_is_reachable() {
        assert!(!engine_description().is_empty());
    }

    /// A compile-time canary: if someone adds an SSH dependency to this crate,
    /// this module is where the reviewer is told why that is wrong.
    #[test]
    fn boundary_is_documented() {
        assert!(NO_SSH_DEPENDENCY.contains("no SSH"));
    }
}
