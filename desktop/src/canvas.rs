//! What the workspace draws around the terminals: the dividers of a split
//! tab, and the clear hit areas that take the pointer for a terminal. The
//! cells are the terminals' own child surfaces. A split terminal has no row
//! of its own; the strip's chip is its name, and the selected one carries
//! the accent rule along its top edge (`SplitCanvas`).

use gpui::{
    Context, CursorStyle, IntoElement, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent,
    Render, ScrollDelta, ScrollEvent, Window, div, prelude::*, px, rgb,
};
use tether_desktop::split::{Divider, PaneId};
use tether_ui::{Chrome, Ink, Kind, Rect, Workspace, layout};

use crate::workspace::{Desktop, Drag};

/// `Palette.softDark` background, under the grid while a surface starts.
const CANVAS: u32 = 0x171B22;

/// One terminal's share of the terminal rect.
struct Placed {
    pane: PaneId,
    /// The band above a split terminal's grid that holds its selection rule.
    /// Drawn beside the surface, not over it: the surface covers what is on top.
    rule: Option<Rect>,
    terminal: Rect,
}

impl Render for Desktop {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let viewport = window.viewport_size();
        let (width, height) = (f32::from(viewport.width), f32::from(viewport.height));
        // A resize redraws the whole window, so the size needs no notify. Chips do: `sync`.
        let shape = self.chrome.update(cx, |view, _| {
            view.workspace.width = width;
            view.workspace.height = height;
            view.workspace.clone()
        });
        let (placed, dividers) = self.arrange(&shape, cx);
        self.place_surfaces(&placed, window, cx);
        let ink = self.ink(cx);
        let hole = layout(&shape, &self.chrome.read(cx).tabs).region(Kind::Terminal);
        let selected = self.workspaces.selected();
        let rules: Vec<gpui::Div> = placed
            .iter()
            .filter(|placed| Some(placed.pane) == selected)
            .filter_map(|placed| placed.rule)
            .map(|rect| at(rect).bg(rgb(ink.accent)))
            .collect();
        let areas: Vec<gpui::Div> =
            placed.iter().map(|placed| self.pane_area(placed, cx)).collect();
        let lines: Vec<gpui::Div> =
            dividers.iter().map(|divider| self.divider(divider, ink, cx)).collect();
        div()
            .relative()
            .size_full()
            .bg(rgb(ink.surface))
            .track_focus(&self.focus)
            .on_key_down(cx.listener(Self::key_down))
            .on_mouse_move(cx.listener(|this, event: &MouseMoveEvent, _, cx| {
                this.drag_to(event, cx);
            }))
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(|this, _: &MouseUpEvent, _, _| this.drag = None),
            )
            .children(hole.map(|rect| at(rect).bg(rgb(CANVAS))))
            .children(rules)
            .children(areas)
            .children(lines)
            .child(self.chrome.clone())
    }
}

impl Desktop {
    /// The selected tab's terminals, each filling its share of the terminal rect.
    fn arrange(&self, shape: &Workspace, cx: &Context<Self>) -> (Vec<Placed>, Vec<Divider>) {
        let hole = layout(shape, &self.chrome.read(cx).tabs).region(Kind::Terminal);
        let page = self.workspaces.current();
        let (Some(hole), Some(page)) = (hole, page) else { return (Vec::new(), Vec::new()) };
        let arranged = page.visible().layout(hole);
        let split = arranged.panes.len() > 1;
        let placed = arranged
            .panes
            .into_iter()
            .map(|(pane, rect)| {
                if !split {
                    return Placed { pane, rule: None, terminal: rect };
                }
                let band = Chrome::RULE.min(rect.height);
                Placed {
                    pane,
                    rule: Some(Rect { height: band, ..rect }),
                    terminal: Rect { y: rect.y + band, height: rect.height - band, ..rect },
                }
            })
            .collect();
        (placed, arranged.dividers)
    }

    /// Lays each visible terminal's surface over its rect and hides the rest.
    /// Starts a surface the first time a terminal has a size.
    fn place_surfaces(&mut self, placed: &[Placed], window: &Window, cx: &mut Context<Self>) {
        let scale = window.scale_factor();
        for (id, pane) in &mut self.panes {
            let Some(rect) = placed.iter().find(|p| p.pane == *id).map(|p| p.terminal) else {
                pane.hide();
                continue;
            };
            let Some(surface) = pane.place(rect, scale, true) else { continue };
            let (width, height) = pane.pixels();
            let id = *id;
            cx.spawn_in(window, async move |this, cx| {
                let started = surface.initialize(width, height).await;
                let _ = this.update(cx, |this, _| {
                    let Some(pane) = this.panes.get_mut(&id) else {
                        surface.close();
                        return;
                    };
                    match started {
                        Ok(()) => {
                            pane.ready(surface);
                            pane.draw();
                        }
                        Err(error) => {
                            eprintln!("tether-desktop: surface: {error}");
                            surface.close();
                            pane.failed();
                        }
                    }
                });
            })
            .detach();
        }
    }

    /// A clear area over the grid. Pressing it selects the terminal; the
    /// wheel over it scrolls it.
    fn pane_area(&self, placed: &Placed, cx: &mut Context<Self>) -> gpui::Div {
        let pane = placed.pane;
        let select =
            move |this: &mut Self, _: &MouseDownEvent, _: &mut Window, cx: &mut Context<Self>| {
                this.select(pane, cx);
            };
        at(placed.terminal).on_mouse_down(MouseButton::Left, cx.listener(select)).on_scroll(
            cx.listener(move |this, event: &ScrollEvent, _, cx| {
                let Some(target) = this.panes.get_mut(&pane) else { return };
                // A trackpad's travel is points, divided by the row; a wheel's is rows.
                let rows = match event.delta {
                    ScrollDelta::Pixels(delta) => match target.line_points() {
                        Some(line) => f32::from(delta.y) / line,
                        None => return,
                    },
                    ScrollDelta::Lines(delta) => delta.y,
                };
                let (x, y) = (f32::from(event.position.x), f32::from(event.position.y));
                target.wheel(rows, x, y, event.modifiers.shift);
                cx.stop_propagation();
            }),
        )
    }

    fn divider(&self, divider: &Divider, ink: Ink, cx: &mut Context<Self>) -> gpui::Div {
        let line = at(divider.line).bg(rgb(ink.separator).opacity(ink.separator_alpha));
        let path = divider.path.clone();
        let cursor =
            if divider.horizontal { CursorStyle::ResizeColumn } else { CursorStyle::ResizeRow };
        let handle = at(divider.handle).cursor(cursor).on_mouse_down(
            MouseButton::Left,
            cx.listener(move |this, _: &MouseDownEvent, _, cx| {
                if let Some(page) = this.workspaces.current().map(|page| page.id) {
                    this.drag = Some(Drag { page, path: path.clone() });
                }
                cx.stop_propagation();
            }),
        );
        div().child(line).child(handle)
    }

    fn drag_to(&mut self, event: &MouseMoveEvent, cx: &mut Context<Self>) {
        let Some(drag) = &self.drag else { return };
        if event.pressed_button != Some(MouseButton::Left) {
            self.drag = None;
            return;
        }
        let shape = self.chrome.read(cx).workspace.clone();
        let (_, dividers) = self.arrange(&shape, cx);
        let Some(divider) = dividers.iter().find(|divider| divider.path == drag.path) else {
            return;
        };
        let fraction =
            divider.fraction_at(f32::from(event.position.x), f32::from(event.position.y));
        self.resize_split(fraction, cx);
    }
}

fn at(rect: Rect) -> gpui::Div {
    div().absolute().left(px(rect.x)).top(px(rect.y)).w(px(rect.width)).h(px(rect.height))
}
