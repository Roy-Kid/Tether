//! Tether's public API: the component a consuming application imports.
//!
//! It binds a remote byte stream to a terminal engine and owns their shared
//! lifecycle. Everything below it — `russh`, `alacritty_terminal`, the async
//! runtime — is an implementation detail a consumer never names (spec §3, §16).
//!
//! The shape a consumer uses:
//!
//! ```no_run
//! # use std::sync::Arc;
//! # use tether_core::{Credential, Dial};
//! # use tether_core::ssh::Endpoint;
//! # use tether_core::terminal::{Input, Key, ScreenSize};
//! # async fn example(
//! #     verifier: Arc<dyn tether_core::ssh::HostVerifier>,
//! # ) -> Result<(), Box<dyn std::error::Error>> {
//! let session = Dial::new(Endpoint::new("example.org", 22), "scientist")
//!     .verifier(verifier)
//!     .size(ScreenSize::new(120, 40))
//!     .connect(vec![Credential::Password("…".into())])
//!     .await?;
//!
//! session.send(&Input::key(Key::Enter))?;
//!
//! while session.changed().await {
//!     render(&session.screen());
//! }
//! # Ok(()) }
//! # fn render(_: &tether_core::terminal::Screen) {}
//! ```

mod dial;
mod session;

pub use dial::{Credential, Dial, DialError};
pub use session::{Ending, SessionError, TerminalSession};

pub use tether_ssh as ssh;
pub use tether_terminal as terminal;

/// What this build is composed of, for diagnostics and about screens.
pub fn composition() -> Vec<String> {
    vec![tether_ssh::backend_description(), tether_terminal::engine_description().to_owned()]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn composition_names_both_engines() {
        let parts = composition();
        assert_eq!(parts.len(), 2);
        assert!(parts.iter().any(|p| p.starts_with("russh")));
        assert!(parts.iter().any(|p| p.contains("alacritty")));
    }
}
