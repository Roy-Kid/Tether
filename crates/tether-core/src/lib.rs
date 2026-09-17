//! Tether's public API: the component a consuming application imports.
//!
//! It binds a remote byte stream to a terminal engine and owns their shared
//! lifecycle. Everything below it — `russh`, `alacritty_terminal`, the async
//! runtime — is an implementation detail a consumer never names (spec §3, §16).

pub use tether_ssh as ssh;
pub use tether_terminal as terminal;

/// What this build is composed of, for diagnostics and about screens.
pub fn composition() -> Vec<String> {
    vec![
        tether_ssh::backend_description(),
        tether_terminal::engine_description().to_owned(),
    ]
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
