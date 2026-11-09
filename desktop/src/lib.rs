//! The desktop host's own logic, free of any toolkit.
//!
//! The window, the chrome view and the terminal surface are the binary
//! (`--features gui`). What is here is what a host decides — which tab is
//! selected, which key is which — so the commit gate tests it without
//! compiling GPUI.

pub mod activity;
pub mod dialog;
pub mod foreground;
pub mod hosts;
pub mod keys;
pub mod known_hosts;
pub mod labels;
pub mod links;
pub mod login;
pub mod selection;
pub mod split;
pub mod tab_menu;
pub mod workspaces;
