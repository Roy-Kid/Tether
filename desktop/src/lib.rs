//! The desktop host's own logic, free of any toolkit.
//!
//! The window, the chrome view and the terminal surface are the binary
//! (`--features gui`). What is here is what a host decides — which tab is
//! selected, which key is which — so the commit gate tests it without
//! compiling GPUI.

pub mod foreground;
pub mod keys;
pub mod labels;
pub mod split;
pub mod workspaces;
