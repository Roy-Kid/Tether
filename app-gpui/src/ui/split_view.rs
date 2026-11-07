use gpui::{
    AnyElement, Context, IntoElement, MouseButton, ParentElement, Styled, canvas, div, prelude::*,
    px, rgb,
};

use crate::chrome::{ChromeColors, ChromeMetrics};
use crate::terminal::TerminalHost;
use crate::workspace::{Axis, Node, PaneId, Session};

use super::tabs::{StripChrome, tab_strip};
use super::workspace_view::WorkspaceView;

#[derive(Clone, Copy)]
struct Viewport<'a> {
    terminal: &'a TerminalHost,
    show: bool,
    dark: bool,
}

#[derive(Clone, Copy)]
struct PaneFrame {
    ends: StripChrome,
    maximized: bool,
    colors: ChromeColors,
    metrics: ChromeMetrics,
}

pub(crate) struct TerminalPane {
    pub maximized: bool,
    pub show: bool,
    pub dark: bool,
}

pub(crate) fn split_tree(
    view: &WorkspaceView,
    session: &Session,
    pane: TerminalPane,
    colors: ChromeColors,
    metrics: ChromeMetrics,
    cx: &mut Context<WorkspaceView>,
) -> impl IntoElement + use<> {
    let TerminalPane { maximized, show: show_terminal, dark } = pane;
    let tree = render_node(
        view,
        session.model.root(),
        session.model.focused_pane(),
        PaneFrame {
            ends: StripChrome { on_top: true, leading: true, trailing: true },
            maximized,
            colors,
            metrics,
        },
        Viewport { terminal: &view.terminal, show: show_terminal, dark },
        cx,
    );
    div()
        .flex()
        .flex_col()
        .flex_grow(1.)
        .flex_shrink(1.)
        .min_h(px(0.))
        .w_full()
        .overflow_hidden()
        .bg(rgb(colors.window))
        .child(tree)
}

fn render_node(
    view: &WorkspaceView,
    node: &Node,
    focused: PaneId,
    frame: PaneFrame,
    viewport: Viewport<'_>,
    cx: &mut Context<WorkspaceView>,
) -> AnyElement {
    match node {
        Node::Pane(pane) => pane_view(view, pane, focused, frame, viewport, cx).into_any_element(),
        Node::Split { axis, ratio, first, second } => {
            let (first_ends, second_ends) = match axis {
                Axis::Vertical => {
                    (frame.ends, StripChrome { on_top: false, leading: false, trailing: false })
                }
                Axis::Horizontal => (
                    StripChrome {
                        on_top: frame.ends.on_top,
                        leading: frame.ends.leading,
                        trailing: false,
                    },
                    StripChrome {
                        on_top: frame.ends.on_top,
                        leading: false,
                        trailing: frame.ends.trailing,
                    },
                ),
            };
            let first = render_node(
                view,
                first,
                focused,
                PaneFrame { ends: first_ends, ..frame },
                Viewport { ..viewport },
                cx,
            );
            let second = render_node(
                view,
                second,
                focused,
                PaneFrame { ends: second_ends, ..frame },
                Viewport { ..viewport },
                cx,
            );
            let split =
                div().size_full().flex().when(*axis == Axis::Vertical, |this| this.flex_col());
            let split = match axis {
                Axis::Horizontal => split
                    .child(div().w(gpui::relative(*ratio)).h_full().child(first))
                    .child(div().flex_grow(1.).min_w(px(0.)).h_full().child(second)),
                Axis::Vertical => split
                    .child(div().h(gpui::relative(*ratio)).w_full().child(first))
                    .child(div().flex_grow(1.).min_h(px(0.)).w_full().child(second)),
            };
            split.into_any_element()
        }
    }
}

fn pane_view(
    view: &WorkspaceView,
    pane: &crate::workspace::Pane,
    focused: PaneId,
    frame: PaneFrame,
    viewport: Viewport<'_>,
    cx: &mut Context<WorkspaceView>,
) -> impl IntoElement + use<> {
    let pane_id = pane.id;
    let is_focused = pane.id == focused;
    let Viewport { terminal, show: show_terminal, dark } = viewport;
    let PaneFrame { ends, maximized, colors, metrics } = frame;
    let tabs = tab_strip(view, pane, ends, maximized, colors, metrics, cx);
    let focus_canvas = cx.listener(move |this, _, window, cx| {
        this.session.update(cx, |session, cx| {
            session.model.focus_pane(pane_id);
            cx.notify();
        });
        this.focus.focus(window, cx);
    });
    div()
        .flex()
        .flex_col()
        .flex_grow(1.)
        .min_w(px(0.))
        .min_h(px(0.))
        .w_full()
        .when(is_focused, |this| this.border_1().border_color(rgb(colors.accent)))
        .child(tabs)
        .child(
            div()
                .flex()
                .flex_col()
                .flex_grow(1.)
                .min_h(px(0.))
                .w_full()
                .p(px(metrics.canvas_inset))
                .bg(rgb(colors.window))
                .cursor_pointer()
                .on_mouse_down(MouseButton::Left, focus_canvas)
                .child({
                    let terminal = terminal.clone();
                    canvas(
                        move |bounds, window, _| {
                            if is_focused {
                                terminal.place(window, bounds, show_terminal, dark);
                            }
                        },
                        |_, _, _, _| {},
                    )
                    .flex_grow(1.)
                    .min_h(px(0.))
                    .w_full()
                    .bg(rgb(colors.canvas))
                }),
        )
}
