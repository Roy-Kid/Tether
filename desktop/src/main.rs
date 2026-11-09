//! `tether-desktop`: the Windows and Mac host (Decisions/0022).
//!
//! GPUI owns the window. `tether-ui` paints the chrome; each tab's terminal
//! is `tether-render` drawing into a child surface laid over the terminal
//! rect. Sessions run on a tokio runtime and are the same `tether-ffi`
//! objects the Swift and C# hosts use, so input encoding and frame deltas
//! are one implementation. What only a platform has is `platform/`.

mod canvas;
mod ime;
mod pane;
mod platform;
mod pointer;
mod workspace;

fn main() {
    if let Err(error) = workspace::run() {
        eprintln!("tether-desktop: {error}");
        std::process::exit(1);
    }
}
