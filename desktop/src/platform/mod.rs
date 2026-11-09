//! What only a platform can do. The workspace calls these and names no OS.

#[cfg(target_os = "macos")]
mod mac;
#[cfg(target_os = "macos")]
mod mac_dialog;
#[cfg(target_os = "macos")]
mod mac_menu;
#[cfg(target_os = "macos")]
mod mac_preedit;
#[cfg(target_os = "macos")]
mod mac_symbols;
#[cfg(target_os = "macos")]
pub use mac::{TerminalLayer, foreground_command, place_window};
#[cfg(target_os = "macos")]
pub use mac_dialog::ask;
#[cfg(target_os = "macos")]
pub use mac_menu::menu;

/// The chrome's marks as this platform draws them, or `None` for the bundled ones.
#[cfg(target_os = "macos")]
pub fn symbols() -> Option<std::sync::Arc<dyn tether_ui::Symbols>> {
    Some(std::sync::Arc::new(mac_symbols::SfSymbols::default()))
}

#[cfg(not(target_os = "macos"))]
pub fn symbols() -> Option<std::sync::Arc<dyn tether_ui::Symbols>> {
    None
}

#[cfg(not(target_os = "macos"))]
mod unsupported;
#[cfg(not(target_os = "macos"))]
pub use unsupported::{TerminalLayer, ask, foreground_command, menu, place_window};
