//! Terminal state → GPU draw.
//!
//! `tether-terminal` produces screen state and damage; this crate turns a
//! frame into pixels. It sits beside the core, never inside it (spec §14), so
//! the same core serves a SwiftUI view, a WinUI view, a web view, a headless
//! test and a renderer that does not exist yet.
//!
//! What is composed (spec §4): [`wgpu`] for GPU submission, [`cosmic-text`]
//! for shaping and font fallback, [`glyphon`] for the glyph atlas. What is
//! written here is the terminal-specific part — grid layout, cursor, damage
//! driven redraw, the theming surface (spec §14).
//!
//! This crate is headless-first: [`layout::prepare`] is pure, and its tests
//! link no UI framework and no GPU (spec §8, §15).

mod draw;
mod frame;
mod layout;
mod metrics;
mod palette;
mod renderer;

pub use draw::{BgRect, Cell, CellSpan, CursorQuad, DrawList, LinkUnderline, Overlay, Rgba, TextRun};
pub use frame::{Caret, Frame, Name, Paint, Row, Run, RunStyle, Underline};
pub use layout::{prepare, prepare_with_overlay};
pub use metrics::FontMetrics;
pub use palette::Palette;
pub use renderer::{measure_monospace, RenderError, SurfaceSize, TerminalRenderer};

/// The byte-stream boundary in executable form, restated for the
/// presentation layer.
///
/// `tether-render` must never reach a network and must never see an SSH
/// type. It draws what a frontend contract describes — which is also why
/// `alacritty_terminal`'s types stop inside `tether-terminal` and never
/// arrive here (spec §3, §8).
pub const NO_SSH_DEPENDENCY: &str =
    "tether-render links no SSH symbol and no UI toolkit type; it draws a frontend contract";

/// Which GPU text stack answers, for diagnostics and about screens.
///
/// Named for the same reason [`tether_terminal::engine_description`] names
/// the VT engine: a rendering bug is reported against a stack, not against
/// "a renderer".
pub fn render_stack_description() -> &'static str {
    // The pins in `Cargo.toml` are the authority (Decisions/0016).
    "wgpu + cosmic-text + glyphon"
}
