//! SSH: transport, authentication, host trust, channels and interactive shells.
//!
//! [`russh`] provides the protocol. This crate owns what a consumer sees:
//! domain types, the error model, host-trust policy, and the shape of an
//! interactive authentication exchange. `russh` types stop here (spec §8).
//!
//! Nothing in this crate knows about terminal grids, colours or cursors.

/// Whether the SSH stack is reachable, and which implementation answers.
///
/// Phase 1 replaces this with connect / authenticate / verify / shell.
pub fn backend_description() -> String {
    format!("russh {}", russh_version())
}

fn russh_version() -> &'static str {
    // russh does not expose its own version string; the pin in Cargo.toml is
    // the authority, and this is where a future probe will live.
    "0.63"
}

/// Keyboard-interactive is not a synonym for one-time passwords.
///
/// A server may use it for a password, an OTP, a token, a challenge/response,
/// a factor selection, or its own institutional wording. The protocol layer
/// reports prompts; a higher layer decides how a person answers them
/// (spec §10). Encoded here as a constant so the rule is visible at the point
/// the temptation arises.
pub const KEYBOARD_INTERACTIVE_IS_GENERIC: &str =
    "prompts are opaque text with an echo flag; never assume OTP";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backend_is_reachable() {
        assert!(backend_description().starts_with("russh"));
    }

    #[test]
    fn keyboard_interactive_stays_generic() {
        assert!(KEYBOARD_INTERACTIVE_IS_GENERIC.contains("never assume OTP"));
    }
}
