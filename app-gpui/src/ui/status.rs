use gpui::{Context, IntoElement, ParentElement, Styled, div, prelude::*, px, rgb};

use crate::chrome::{self, ChromeColors, ChromeMetrics};
use crate::workspace::{Command, Session};

use super::tabs::{Glyph, glyph_button, plus};
use super::workspace_view::{Hover, WorkspaceView};

pub(crate) fn status_bar(
    view: &WorkspaceView,
    session: &Session,
    colors: ChromeColors,
    metrics: ChromeMetrics,
    cx: &mut Context<WorkspaceView>,
) -> impl IntoElement + use<> {
    let host = session
        .model
        .focused_tab()
        .map(|tab| (tab.host_name.clone(), tab.host_detail.clone()))
        .unwrap_or_else(|| ("localhost".into(), "this machine".into()));
    let picker = session.host_picker_open;
    let hosts = session.model.hosts().to_vec();
    let split_right = glyph_button(
        view,
        Glyph { id: "split-right".into(), name: "Split right", hover: Hover::SplitRight, colors },
        plus(colors.text),
        |this, window, cx| this.run(Command::SplitRight, window, cx),
        cx,
    );
    let split_down = glyph_button(
        view,
        Glyph { id: "split-down".into(), name: "Split down", hover: Hover::SplitDown, colors },
        div().w(px(12.)).h(px(2.)).bg(rgb(colors.text)),
        |this, window, cx| this.run(Command::SplitDown, window, cx),
        cx,
    );
    let commands = glyph_button(
        view,
        Glyph { id: "commands".into(), name: "Commands", hover: Hover::Commands, colors },
        div().text_size(px(12.)).child("☰"),
        |this, window, cx| this.open_palette(window, cx),
        cx,
    );
    let settings = glyph_button(
        view,
        Glyph { id: "settings".into(), name: "Settings", hover: Hover::Settings, colors },
        div().size(px(10.)).rounded(px(5.)).border_1().border_color(rgb(colors.text)),
        |this, window, cx| this.run(Command::Settings, window, cx),
        cx,
    );
    let mut host_rows = Vec::new();
    for (index, host) in hosts.iter().enumerate() {
        let name = host.name.clone();
        let picked = name.clone();
        let detail = host.detail.clone();
        let hover = Hover::Host(index);
        let shown = view.hover == Some(hover);
        host_rows.push(
            div()
                .h(px(28.))
                .px(px(chrome::GROUP))
                .flex()
                .items_center()
                .rounded(px(chrome::ROW_RADIUS))
                .cursor_pointer()
                .id(("host", index))
                .when(shown, |this| this.bg(rgb(colors.raised)))
                .on_hover(cx.listener(move |this, hovered: &bool, _, cx| {
                    this.note_hover(hovered.then_some(hover), cx);
                }))
                .on_mouse_down(
                    gpui::MouseButton::Left,
                    cx.listener(move |this, _, _, cx| {
                        this.session.update(cx, |session, cx| {
                            session.model.assign_host_to_focused(&picked);
                            session.host_picker_open = false;
                            cx.notify();
                        });
                    }),
                )
                .child(name)
                .when(shown, |this| {
                    this.child(
                        div()
                            .ml(px(chrome::GROUP))
                            .text_size(px(chrome::DETAIL))
                            .text_color(rgb(colors.secondary))
                            .child(detail),
                    )
                }),
        );
    }

    div()
        .relative()
        .h(px(metrics.status_height))
        .flex_shrink(0.)
        .w_full()
        .flex()
        .items_center()
        .px(px(chrome::GROUP))
        .gap(px(chrome::SMALL))
        .bg(rgb(colors.chrome))
        .border_t_1()
        .border_color(rgb(colors.separator))
        .child(
            div()
                .w(px(chrome::HOST_PICKER_WIDTH))
                .h(px(metrics.status_height))
                .flex()
                .items_center()
                .cursor_pointer()
                .child(host.0)
                .on_mouse_down(
                    gpui::MouseButton::Left,
                    cx.listener(|this, _, window, cx| {
                        this.session.update(cx, |session, cx| {
                            session.host_picker_open = !session.host_picker_open;
                            cx.notify();
                        });
                        this.focus.focus(window, cx);
                    }),
                ),
        )
        .child(div().flex_grow(1.))
        .child(split_right)
        .child(split_down)
        .child(commands)
        .child(settings)
        .when(picker, |this| {
            this.child(
                div()
                    .absolute()
                    .bottom(px(metrics.status_height))
                    .left(px(chrome::GROUP))
                    .w(px(chrome::HOST_PICKER_WIDTH))
                    .id("hosts")
                    .max_h(px(chrome::HOST_LIST_MAX))
                    .overflow_y_scroll()
                    .p(px(chrome::SMALL))
                    .rounded(px(chrome::PANEL_RADIUS))
                    .bg(rgb(colors.window))
                    .border_1()
                    .border_color(rgb(colors.separator))
                    .child(div().flex().flex_col().children(host_rows)),
            )
        })
}
