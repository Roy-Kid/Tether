mod chrome;
mod terminal;
mod ui;
mod workspace;

use gpui::{App, Bounds, prelude::*, px, size};
use gpui_platform::application;

fn main() {
    application().run(|cx: &mut App| {
        ui::bind_keys(cx);
        cx.set_app_identity("TetherDesktopPreview", "Tether Desktop");
        let session = cx.new(|_| {
            let mut session = workspace::Session::fixture();
            session.model.focus_first_local();
            session
        });
        let bounds =
            Bounds::centered(None, size(px(chrome::WINDOW_WIDTH), px(chrome::WINDOW_HEIGHT)), cx);
        cx.open_window(
            ui::desktop_window(
                "Tether Desktop",
                bounds,
                Some(size(px(chrome::WINDOW_MIN_WIDTH), px(chrome::WINDOW_MIN_HEIGHT))),
            ),
            |window, cx| {
                window.set_window_title("Tether Desktop");
                let view = cx.new(|cx| ui::WorkspaceView::new(session, cx));
                view.read(cx).focus_handle().focus(window, cx);
                view
            },
        )
        .unwrap();
        cx.activate(true);
    });
}
