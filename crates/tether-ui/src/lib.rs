//! Shared window chrome for Windows and macOS.
//!
//! Three layers, and this crate is only the first:
//!
//! - **UI.** [`layout`] is the geometry of the workspace the Mac app already
//!   shows. With the `gpui` feature, [`ChromeView`] paints that chrome. The
//!   feature is off by default, so the commit gate does not compile a UI toolkit.
//! - **Terminal.** The cell grid is a hole ([`Role::Terminal`]). `tether-render`
//!   draws it. This crate does not depend on that renderer, and that renderer
//!   does not depend on this crate.
//! - **Platform services.** The window, menus, traffic lights, iCloud, Keychain
//!   and the credential extension stay in the host. The host passes
//!   [`Workspace::leading_reserve`] for the strip it paints itself. This crate
//!   does not open a window.
//!
//! iOS stays on its own SwiftUI and is not laid out here.

mod chrome;
mod frame;
mod line;

#[cfg(feature = "gpui")]
mod field;
#[cfg(feature = "gpui")]
mod icons;
#[cfg(feature = "gpui")]
mod view;

pub use chrome::Chrome;
pub use frame::{
    Canvas, Frame, Hit, Kind, Placement, Rect, Region, Role, Side, Tab, Workspace, layout,
};
pub use line::Line;

#[cfg(feature = "gpui")]
pub use field::{FieldEvent, TextField};
#[cfg(feature = "gpui")]
pub use icons::{Assets, Drawn, Icon, Style, Symbols};
#[cfg(feature = "gpui")]
pub use view::{ChromeEvent, ChromeView, HostRow, Ink, Mark, Presence, Rename};

/// The boundary in executable form, beside the `cargo tree` check.
pub const BOUNDARY: &str = "tether-ui paints shared chrome, leaves the terminal and plugin surfaces empty, and leaves the window and platform services to the host";
