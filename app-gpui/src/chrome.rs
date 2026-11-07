//! Spacing and color roles from the UI contract. Numbers, not a second layout.

use crate::workspace::ThemeChoice;

pub const TIGHT: f32 = 2.;
pub const SMALL: f32 = 4.;
pub const INLINE: f32 = 6.;
pub const GROUP: f32 = 8.;
pub const INSET: f32 = 12.;
pub const SECTION: f32 = 16.;
pub const TITLE: f32 = 12.;
pub const DETAIL: f32 = 11.;
pub const HEADER: f32 = 10.;
pub const INPUT: f32 = 13.;
pub const ROW_RADIUS: f32 = 4.;
pub const PANEL_RADIUS: f32 = 10.;
pub const TAB_TITLE_MAX: f32 = 180.;
pub const HOST_PICKER_WIDTH: f32 = 280.;
pub const HOST_LIST_MAX: f32 = 280.;
pub const COMMAND_PANEL_WIDTH: f32 = 420.;
pub const WINDOW_WIDTH: f32 = 1100.;
pub const WINDOW_HEIGHT: f32 = 700.;
pub const WINDOW_MIN_WIDTH: f32 = 860.;
pub const WINDOW_MIN_HEIGHT: f32 = 520.;
/// Width the Mac titlebar leaves clear for the traffic lights (`Chrome.trafficLights`).
pub const TRAFFIC_LIGHTS: f32 = 76.;
/// Left edge of the traffic lights, and the shortest empty drag region beside the tabs.
pub const TRAFFIC_LIGHT_X: f32 = 12.;
pub const TRAFFIC_BUTTON: f32 = 14.;
pub const DRAG_MIN: f32 = 12.;
/// One Windows caption button. Three of them sit at the trailing end of the titlebar row.
pub const CAPTION_BUTTON: f32 = 46.;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DesktopOs {
    Windows,
    Mac,
}

impl DesktopOs {
    pub fn current() -> Self {
        if cfg!(target_os = "macos") { Self::Mac } else { Self::Windows }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ChromeMetrics {
    pub canvas_inset: f32,
    pub tab_height: f32,
    pub status_height: f32,
    pub ui_font: Option<&'static str>,
    /// The system draws the traffic lights, so the titlebar row leaves a gap.
    pub reserves_traffic_lights: bool,
    /// The system titlebar is hidden, so the row draws minimize, maximize, and close.
    pub caption_buttons: bool,
}

impl ChromeMetrics {
    pub fn for_os(os: DesktopOs) -> Self {
        match os {
            // Windows canvas is flush. Status row is at least 32; the
            // one-unit separator sits outside this height.
            DesktopOs::Windows => Self {
                canvas_inset: 0.,
                tab_height: 32.,
                status_height: 32.,
                ui_font: Some("Segoe UI"),
                reserves_traffic_lights: false,
                caption_buttons: true,
            },
            // The tab row is the titlebar (`Chrome.tab` is 32). The 12-unit inset
            // belongs to the canvas under that row, and the status bar is 24.
            DesktopOs::Mac => Self {
                canvas_inset: INSET,
                tab_height: 32.,
                status_height: 24.,
                ui_font: None,
                reserves_traffic_lights: true,
                caption_buttons: false,
            },
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ChromeColors {
    pub window: u32,
    pub chrome: u32,
    pub raised: u32,
    pub text: u32,
    pub secondary: u32,
    pub accent: u32,
    pub canvas: u32,
    pub danger: u32,
    pub separator: u32,
}

pub fn colors(choice: ThemeChoice, system_dark: bool) -> ChromeColors {
    if choice.is_dark(system_dark) { dark() } else { light() }
}

fn dark() -> ChromeColors {
    ChromeColors {
        window: 0x1f1f1f,
        chrome: 0x2b2b2b,
        raised: 0x383838,
        text: 0xf3f3f3,
        secondary: 0xa0a0a0,
        accent: 0x0078d4,
        canvas: 0x0c0c0c,
        danger: 0xc42b1c,
        separator: 0x3a3a3a,
    }
}

fn light() -> ChromeColors {
    ChromeColors {
        window: 0xf3f3f3,
        chrome: 0xfafafa,
        raised: 0xe5e5e5,
        text: 0x1a1a1a,
        secondary: 0x616161,
        accent: 0x005fb8,
        canvas: 0xffffff,
        danger: 0xc42b1c,
        separator: 0xe0e0e0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn platform_metrics_follow_the_contract() {
        let windows = ChromeMetrics::for_os(DesktopOs::Windows);
        assert_eq!(windows.canvas_inset, 0.);
        assert!(windows.status_height >= 32.);
        assert_eq!(windows.ui_font, Some("Segoe UI"));
        assert!(!windows.reserves_traffic_lights);
        assert!(windows.caption_buttons);
        let mac = ChromeMetrics::for_os(DesktopOs::Mac);
        assert_eq!(mac.canvas_inset, 12.);
        assert_eq!(mac.tab_height, 32.);
        assert_eq!(mac.status_height, 24.);
        assert_eq!(mac.ui_font, None);
        assert!(mac.reserves_traffic_lights);
        assert!(!mac.caption_buttons);
    }

    #[test]
    fn theme_choice_overrides_the_system() {
        assert!(ThemeChoice::Dark.is_dark(false));
        assert!(!ThemeChoice::Light.is_dark(true));
        assert!(ThemeChoice::System.is_dark(true));
        assert!(!ThemeChoice::System.is_dark(false));
        assert_ne!(
            colors(ThemeChoice::Dark, false).canvas,
            colors(ThemeChoice::Light, true).canvas
        );
    }
}
