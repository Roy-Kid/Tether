use gpui::{
    Context, IntoElement, MouseButton, MouseDownEvent, ParentElement, Styled, Window,
    WindowControlArea, div, prelude::*, px, rgb,
};

use crate::chrome::{self, ChromeColors, ChromeMetrics};
use crate::workspace::{Command, Pane};

use super::workspace_view::{Hover, WorkspaceView};

/// Which edges of a pane's tab row belong to the window titlebar.
#[derive(Clone, Copy)]
pub(crate) struct StripChrome {
    pub on_top: bool,
    pub leading: bool,
    pub trailing: bool,
}

pub(crate) fn tab_strip(
    view: &WorkspaceView,
    pane: &Pane,
    ends: StripChrome,
    maximized: bool,
    colors: ChromeColors,
    metrics: ChromeMetrics,
    cx: &mut Context<WorkspaceView>,
) -> impl IntoElement + use<> {
    let pane_id = pane.id;
    let selected = pane.selected;
    let mut tabs = Vec::new();
    for (index, tab) in pane.tabs.iter().enumerate() {
        let id = tab.id;
        let title = tab.title.clone();
        let fill = if index == selected { colors.canvas } else { colors.chrome };
        let close = glyph_button(
            view,
            Glyph { id: ("close", id.0).into(), name: "Close", hover: Hover::TabClose(id), colors },
            div().text_size(px(12.)).text_color(rgb(colors.secondary)).child("×"),
            move |this, window, cx| {
                cx.stop_propagation();
                this.close_tab(id, window, cx);
            },
            cx,
        );
        let select = cx.listener(move |this, _, window, cx| {
            this.session.update(cx, |session, cx| {
                session.model.focus_tab(id);
                cx.notify();
            });
            this.focus.focus(window, cx);
        });
        let middle = cx.listener(move |this, _, window, cx| {
            this.close_tab(id, window, cx);
        });
        tabs.push(
            div()
                .h(px(metrics.tab_height))
                .max_w(px(chrome::TAB_TITLE_MAX))
                .flex()
                .items_center()
                .gap(px(chrome::SMALL))
                .px(px(chrome::GROUP))
                .bg(rgb(fill))
                .border_b_1()
                .border_color(rgb(if index == selected { colors.accent } else { fill }))
                .cursor_pointer()
                .on_mouse_down(MouseButton::Left, select)
                .on_mouse_down(MouseButton::Middle, middle)
                .child(div().overflow_hidden().whitespace_nowrap().text_ellipsis().child(title))
                .child(close),
        );
    }
    let new_tab = glyph_button(
        view,
        Glyph { id: ("new", pane_id.0).into(), name: "New tab", hover: Hover::NewTab, colors },
        plus(colors.text),
        move |this, window, cx| {
            this.session.update(cx, |session, cx| {
                session.model.focus_pane(pane_id);
                cx.notify();
            });
            this.run(Command::NewTab, window, cx);
        },
        cx,
    );

    let row = px(metrics.tab_height);
    let traffic = (ends.on_top && ends.leading && metrics.reserves_traffic_lights)
        .then(|| div().w(px(chrome::TRAFFIC_LIGHTS)).h(row));
    let drag_id = ("titlebar", pane_id.0);
    let spacer = if ends.on_top {
        drag_region(drag_id.into()).into_any_element()
    } else {
        div().flex_grow(1.).min_w(px(chrome::DRAG_MIN)).h(row).into_any_element()
    };
    let caption = (ends.on_top && ends.trailing && metrics.caption_buttons)
        .then(|| caption_buttons(colors, maximized));

    div()
        .h(row)
        .w_full()
        .flex()
        .bg(rgb(colors.chrome))
        .border_b_1()
        .border_color(rgb(colors.separator))
        .children(traffic)
        .children(tabs)
        .child(new_tab)
        .child(spacer)
        .children(caption)
}

/// The empty titlebar. A drag moves the window; a double-click zooms it.
pub(crate) fn drag_region(id: gpui::ElementId) -> impl IntoElement {
    div()
        .id(id)
        .h_full()
        .flex_grow(1.)
        .min_w(px(chrome::DRAG_MIN))
        .window_control_area(WindowControlArea::Drag)
        .on_mouse_down(MouseButton::Left, |event: &MouseDownEvent, window, _| {
            if event.click_count > 1 {
                window.titlebar_double_click();
            } else {
                window.start_window_move();
            }
        })
}

/// Settings has no tabs. The row is only the traffic-light gap, the drag, and caption buttons.
pub(crate) fn plain_titlebar(
    colors: ChromeColors,
    metrics: ChromeMetrics,
    maximized: bool,
) -> impl IntoElement {
    let row = px(metrics.tab_height);
    let traffic =
        metrics.reserves_traffic_lights.then(|| div().w(px(chrome::TRAFFIC_LIGHTS)).h(row));
    let caption = metrics.caption_buttons.then(|| caption_buttons(colors, maximized));
    div()
        .h(row)
        .w_full()
        .flex_shrink(0.)
        .flex()
        .bg(rgb(colors.chrome))
        .border_b_1()
        .border_color(rgb(colors.separator))
        .children(traffic)
        .child(drag_region("settings-titlebar".into()))
        .children(caption)
}

fn caption_buttons(colors: ChromeColors, maximized: bool) -> impl IntoElement {
    div()
        .h_full()
        .flex()
        .flex_shrink(0.)
        .child(caption_button(
            "caption-min",
            "Minimize",
            WindowControlArea::Min,
            colors,
            colors.raised,
            div().w(px(10.)).h(px(1.)).bg(rgb(colors.text)),
        ))
        .child(caption_button(
            "caption-max",
            "Zoom",
            WindowControlArea::Max,
            colors,
            colors.raised,
            zoom_mark(colors.text, maximized),
        ))
        .child(caption_button(
            "caption-close",
            "Close",
            WindowControlArea::Close,
            colors,
            colors.danger,
            div().text_size(px(14.)).text_color(rgb(colors.text)).child("×"),
        ))
}

fn caption_button(
    id: &'static str,
    name: &'static str,
    area: WindowControlArea,
    colors: ChromeColors,
    hover: u32,
    glyph: impl IntoElement,
) -> impl IntoElement {
    div()
        .id(id)
        .group(id)
        .relative()
        .h_full()
        .w(px(chrome::CAPTION_BUTTON))
        .flex()
        .items_center()
        .justify_center()
        .window_control_area(area)
        .hover(|style| style.bg(rgb(hover)))
        .child(glyph)
        .child(
            div()
                .absolute()
                .top(px(36.))
                .left(px(chrome::GROUP))
                .opacity(0.)
                .group_hover(id, |style| style.opacity(1.))
                .px(px(chrome::INLINE))
                .py(px(chrome::TIGHT))
                .rounded(px(chrome::ROW_RADIUS))
                .bg(rgb(colors.raised))
                .text_size(px(chrome::DETAIL))
                .text_color(rgb(colors.text))
                .child(name),
        )
}

fn zoom_mark(color: u32, maximized: bool) -> impl IntoElement {
    let mark = div().size(px(10.)).border_1().border_color(rgb(color));
    if maximized {
        div().relative().size(px(12.)).child(mark.absolute().top(px(2.)).left(px(0.))).child(
            div()
                .absolute()
                .top(px(0.))
                .left(px(2.))
                .size(px(10.))
                .border_1()
                .border_color(rgb(color)),
        )
    } else {
        mark
    }
}

pub(crate) struct Glyph {
    pub id: gpui::ElementId,
    pub name: &'static str,
    pub hover: Hover,
    pub colors: ChromeColors,
}

pub(crate) fn glyph_button<T: IntoElement, U>(
    view: &WorkspaceView,
    button: Glyph,
    glyph: T,
    on_press: U,
    cx: &mut Context<WorkspaceView>,
) -> impl IntoElement + use<T, U>
where
    U: Fn(&mut WorkspaceView, &mut Window, &mut Context<WorkspaceView>) + 'static,
{
    let hover = button.hover;
    let colors = button.colors;
    let name = button.name;
    let shown = view.hover == Some(hover);
    div()
        .id(button.id)
        .relative()
        .size(px(24.))
        .flex()
        .items_center()
        .justify_center()
        .rounded(px(chrome::ROW_RADIUS))
        .cursor_pointer()
        .when(shown, |this| this.bg(rgb(colors.raised)))
        .on_hover(cx.listener(move |this, hovered: &bool, _, cx| {
            this.note_hover(hovered.then_some(hover), cx);
        }))
        .on_mouse_down(
            MouseButton::Left,
            cx.listener(move |this, _, window, cx| on_press(this, window, cx)),
        )
        .child(glyph)
        .when(shown, |this| this.child(tip(name, colors)))
}

pub(crate) fn plus(color: u32) -> impl IntoElement {
    div()
        .relative()
        .size(px(12.))
        .child(div().absolute().top(px(5.)).w(px(12.)).h(px(2.)).bg(rgb(color)))
        .child(div().absolute().left(px(5.)).w(px(2.)).h(px(12.)).bg(rgb(color)))
}

pub(crate) fn tip(name: &'static str, colors: ChromeColors) -> impl IntoElement {
    div()
        .absolute()
        .bottom(px(28.))
        .px(px(chrome::INLINE))
        .py(px(chrome::TIGHT))
        .rounded(px(chrome::ROW_RADIUS))
        .bg(rgb(colors.raised))
        .text_size(px(chrome::DETAIL))
        .text_color(rgb(colors.text))
        .child(name)
}
