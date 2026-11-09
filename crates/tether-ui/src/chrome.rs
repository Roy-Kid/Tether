//! Metrics the shared chrome matches.
//!
//! The numbers are the macOS workspace: `Chrome` in
//! `app/Sources/TetherApp/Design.swift`, and `UIStyle` in
//! `app/Packages/TetherFrontend/Sources/TetherUI/Chrome.swift`.
//! iOS uses a shorter strip and is not this crate. Windows passes a zero
//! leading reserve; its caption is the window's, outside this layout.

/// Shared chrome metrics. A change here has to land in the Mac `Chrome` and
/// `UIStyle` it is copied from, or the two UIs stop being the same strip.
pub struct Chrome;

impl Chrome {
    /// Titlebar row on a Mac. Traffic lights are centred in it.
    pub const TAB: f32 = 32.0;
    /// A sidebar tab stacks a title and a subtitle.
    pub const TAB_SIDEBAR_ROW: f32 = 36.0;
    /// Host bar under the terminal.
    pub const STATUS: f32 = 24.0;
    /// Width the Mac host paints as traffic lights. Windows passes 0.
    pub const TRAFFIC_LIGHTS: f32 = 76.0;
    pub const MARGIN: f32 = 12.0;
    pub const TAB_TITLE_WIDTH: f32 = 144.0;
    /// The close glyph. The control that holds it is [`Self::ICON`] wide.
    pub const TAB_CLOSE: f32 = 9.0;
    pub const TAB_SIDEBAR_MIN: f32 = 180.0;
    pub const TAB_SIDEBAR_IDEAL: f32 = 220.0;
    pub const TAB_SIDEBAR_MAX: f32 = 320.0;
    pub const INSPECTOR_MIN: f32 = 240.0;
    pub const INSPECTOR_IDEAL: f32 = 280.0;
    pub const INSPECTOR_MAX: f32 = 480.0;
    /// Grab area centred on a column edge. It does not add layout width.
    pub const COLUMN_HANDLE: f32 = 7.0;
    /// Same height as [`Self::TAB`] on a Mac. Zen keeps this strip and drops the chips.
    pub const TITLEBAR: f32 = 32.0;
    pub const WINDOW_MIN_WIDTH: f32 = 760.0;
    pub const WINDOW_MIN_HEIGHT: f32 = 460.0;
    pub const WINDOW_WIDTH: f32 = 1100.0;
    pub const WINDOW_HEIGHT: f32 = 700.0;

    pub const SPACE_TIGHT: f32 = 2.0;
    pub const SPACE_SMALL: f32 = 4.0;
    pub const SPACE_INLINE: f32 = 6.0;
    pub const SPACE_GROUP: f32 = 8.0;
    pub const SPACE_INSET: f32 = 12.0;

    pub const HAIRLINE: f32 = 1.0;
    pub const RULE: f32 = 2.0;
    pub const PRESENCE: f32 = 7.0;
    pub const ICON: f32 = 18.0;

    /// `UIStyle.rowRadius`. A selected chip washes the accent through this rect.
    pub const ROW_RADIUS: f32 = 4.0;
    /// `UIStyle.selectionOpacity`.
    pub const SELECTION_OPACITY: f32 = 0.12;
    /// `UIStyle.title` on a Mac. Horizontal chips draw it at medium weight.
    pub const TITLE: f32 = 12.0;
    /// `UIStyle.detail` on a Mac.
    pub const DETAIL: f32 = 11.0;
}
