use gpui::{
    Context, IntoElement, KeyDownEvent, MouseButton, ParentElement, Styled, div, prelude::*, px,
    rgb,
};

use crate::chrome::{self, ChromeColors};
use crate::workspace::{self, Session};

use super::workspace_view::WorkspaceView;

pub(crate) fn palette(
    view: &WorkspaceView,
    session: &Session,
    colors: ChromeColors,
    cx: &mut Context<WorkspaceView>,
) -> impl IntoElement + use<> {
    let commands = workspace::matching_commands(&session.palette_query);
    let selected = session.palette_index;
    let mut rows = Vec::new();
    for (index, command) in commands.iter().copied().enumerate() {
        let name = workspace::command_name(command);
        rows.push(
            div()
                .h(px(28.))
                .px(px(chrome::GROUP))
                .flex()
                .items_center()
                .rounded(px(chrome::ROW_RADIUS))
                .cursor_pointer()
                .when(index == selected, |this| this.bg(rgb(colors.raised)))
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(move |this, _, window, cx| this.run(command, window, cx)),
                )
                .child(name),
        );
    }
    let query = session.palette_query.clone();
    let on_key = cx.listener(|this: &mut WorkspaceView, event: &KeyDownEvent, window, cx| {
        this.on_palette_key(event, window, cx);
    });

    div()
        .absolute()
        .size_full()
        .flex()
        .items_center()
        .justify_center()
        .on_mouse_down(
            MouseButton::Left,
            cx.listener(|this, _, window, cx| {
                this.session.update(cx, |session, cx| {
                    session.close_palette();
                    cx.notify();
                });
                this.focus.focus(window, cx);
            }),
        )
        .child(
            div()
                .w(px(chrome::COMMAND_PANEL_WIDTH))
                .max_h(px(360.))
                .flex()
                .flex_col()
                .p(px(chrome::GROUP))
                .gap(px(chrome::SMALL))
                .rounded(px(chrome::PANEL_RADIUS))
                .bg(rgb(colors.window))
                .border_1()
                .border_color(rgb(colors.separator))
                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                .child(
                    div()
                        .h(px(32.))
                        .px(px(chrome::GROUP))
                        .flex()
                        .items_center()
                        .rounded(px(chrome::ROW_RADIUS))
                        .bg(rgb(colors.chrome))
                        .text_size(px(chrome::INPUT))
                        .track_focus(&view.palette_focus)
                        .on_key_down(on_key)
                        .child(if query.is_empty() { " ".to_string() } else { query }),
                )
                .children(rows),
        )
}
