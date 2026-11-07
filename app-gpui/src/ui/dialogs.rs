use gpui::{Context, IntoElement, MouseButton, ParentElement, Styled, div, prelude::*, px, rgb};

use crate::chrome::{self, ChromeColors};

use super::workspace_view::WorkspaceView;

pub(crate) fn dialog(
    view: &WorkspaceView,
    colors: ChromeColors,
    cx: &mut Context<WorkspaceView>,
) -> impl IntoElement + use<> {
    let on_key = cx.listener(|this, event: &gpui::KeyDownEvent, window, cx| {
        if event.keystroke.key == "escape" {
            this.cancel_dialog(window, cx);
        }
    });
    let close = verb("Close", colors, true, cx);
    let cancel = verb("Cancel", colors, false, cx);
    div()
        .absolute()
        .size_full()
        .flex()
        .items_center()
        .justify_center()
        .bg(gpui::hsla(0., 0., 0., 0.35))
        .track_focus(&view.dialog_focus)
        .on_key_down(on_key)
        .child(
            div()
                .w(px(280.))
                .flex()
                .flex_col()
                .gap(px(chrome::GROUP))
                .p(px(chrome::SECTION))
                .rounded(px(chrome::PANEL_RADIUS))
                .bg(rgb(colors.window))
                .border_1()
                .border_color(rgb(colors.separator))
                .child(div().text_size(px(chrome::TITLE)).child("Close tab"))
                .child(div().flex().gap(px(chrome::SMALL)).child(close).child(cancel)),
        )
}

fn verb(
    name: &'static str,
    colors: ChromeColors,
    confirm: bool,
    cx: &mut Context<WorkspaceView>,
) -> impl IntoElement + use<> {
    div()
        .px(px(chrome::INSET))
        .h(px(28.))
        .flex()
        .items_center()
        .rounded(px(chrome::ROW_RADIUS))
        .cursor_pointer()
        .bg(rgb(if confirm { colors.danger } else { colors.raised }))
        .text_color(rgb(if confirm { 0xffffff } else { colors.text }))
        .on_mouse_down(
            MouseButton::Left,
            cx.listener(move |this, _, window, cx| {
                if confirm {
                    this.confirm(window, cx);
                } else {
                    this.cancel_dialog(window, cx);
                }
            }),
        )
        .child(name)
}
