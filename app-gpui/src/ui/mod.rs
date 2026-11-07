mod dialogs;
mod palette;
mod settings;
mod split_view;
mod status;
mod tabs;
mod workspace_view;

pub use workspace_view::WorkspaceView;

use gpui::{
    App, Bounds, KeyBinding, Pixels, Size, TitlebarOptions, WindowBounds, WindowOptions, actions,
    point, px,
};

use crate::chrome::{self, ChromeMetrics, DesktopOs};

/// A window whose tab row is the titlebar. The system title is hidden; the
/// taskbar and the accessibility tree still get `title`.
pub(crate) fn desktop_window(
    title: &str,
    bounds: Bounds<Pixels>,
    min_size: Option<Size<Pixels>>,
) -> WindowOptions {
    let metrics = ChromeMetrics::for_os(DesktopOs::current());
    WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        window_min_size: min_size,
        app_owns_titlebar_drag: true,
        titlebar: Some(TitlebarOptions {
            title: Some(title.into()),
            appears_transparent: true,
            traffic_light_position: Some(point(
                px(chrome::TRAFFIC_LIGHT_X),
                px((metrics.tab_height - chrome::TRAFFIC_BUTTON) / 2.),
            )),
        }),
        ..Default::default()
    }
}

actions!(
    desktop,
    [NewTab, CloseTab, PreviousTab, NextTab, OpenPalette, SplitRight, SplitDown, Wake]
);

pub fn bind_keys(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("ctrl-shift-t", NewTab, Some("Workspace")),
        KeyBinding::new("ctrl-n", NewTab, Some("Workspace")),
        KeyBinding::new("cmd-t", NewTab, Some("Workspace")),
        KeyBinding::new("cmd-n", NewTab, Some("Workspace")),
        KeyBinding::new("ctrl-shift-w", CloseTab, Some("Workspace")),
        KeyBinding::new("ctrl-w", CloseTab, Some("Workspace")),
        KeyBinding::new("ctrl-f4", CloseTab, Some("Workspace")),
        KeyBinding::new("cmd-w", CloseTab, Some("Workspace")),
        // F24 is not a workspace command. The child window posts it so a queued
        // chord is applied on a window that is not already drawing.
        KeyBinding::new("f24", Wake, Some("Workspace")),
        KeyBinding::new("ctrl-pageup", PreviousTab, Some("Workspace")),
        KeyBinding::new("ctrl-pagedown", NextTab, Some("Workspace")),
        KeyBinding::new("cmd-alt-left", PreviousTab, Some("Workspace")),
        KeyBinding::new("cmd-shift-[", PreviousTab, Some("Workspace")),
        KeyBinding::new("cmd-alt-right", NextTab, Some("Workspace")),
        KeyBinding::new("cmd-shift-]", NextTab, Some("Workspace")),
        KeyBinding::new("ctrl-shift-p", OpenPalette, Some("Workspace")),
        KeyBinding::new("alt-shift-p", OpenPalette, Some("Workspace")),
        KeyBinding::new("cmd-shift-o", OpenPalette, Some("Workspace")),
        KeyBinding::new("ctrl-shift-d", SplitRight, Some("Workspace")),
        KeyBinding::new("cmd-\\", SplitRight, Some("Workspace")),
        KeyBinding::new("ctrl-shift-e", SplitDown, Some("Workspace")),
        KeyBinding::new("cmd-shift-\\", SplitDown, Some("Workspace")),
    ]);
}
