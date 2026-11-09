//! What the workspace draws around the terminals: the dividers of a split
//! tab, and the clear hit areas that take the pointer for a terminal. The
//! cells are the terminals' own child surfaces. A split terminal has no row
//! of its own; the strip's chip is its name, and the selected one carries
//! the accent rule along its top edge (`SplitCanvas`).

use gpui::{
    ClipboardItem, Context, CursorStyle, ElementInputHandler, IntoElement, Modifiers, MouseButton,
    MouseDownEvent, MouseMoveEvent, MouseUpEvent, Render, ScrollDelta, ScrollEvent, Window, canvas,
    div, prelude::*, px, rgb,
};
use tether_desktop::split::{Divider, PaneId};
use tether_ffi::PointerButton;
use tether_ui::{Chrome, Ink, Kind, Rect, Workspace, layout};

use crate::pointer::{Cursor, Press};
use crate::workspace::{Desktop, Drag};

/// The buttons a terminal hears, as AppKit's three mouse handlers do.
const BUTTONS: [MouseButton; 3] = [MouseButton::Left, MouseButton::Right, MouseButton::Middle];

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
        let root = div()
            .relative()
            .size_full()
            .bg(rgb(ink.surface))
            .track_focus(&self.focus)
            .on_key_down(cx.listener(Self::key_down))
            .on_mouse_move(cx.listener(|this, event: &MouseMoveEvent, _, cx| {
                this.drag_to(event, cx);
            }))
            // ⌘ let go: no link is underlined any more (`flagsChanged`).
            .on_modifiers_changed(cx.listener(
                |this, event: &gpui::ModifiersChangedEvent, _, _| {
                    if !event.modifiers.platform {
                        for pane in this.panes.values_mut() {
                            if pane.hovered.is_some() {
                                pane.hovered = None;
                                pane.draw();
                            }
                        }
                    }
                },
            ));
        // Ups are heard anywhere in the window: a drag that leaves its terminal still ends.
        BUTTONS
            .into_iter()
            .fold(root, |root, button| {
                root.on_mouse_up(
                    button,
                    cx.listener(move |this, event: &MouseUpEvent, _, cx| {
                        this.pointer_up(button, event, cx);
                    }),
                )
            })
            .children(hole.map(|rect| at(rect).bg(rgb(CANVAS))))
            .child(self.input_target(cx))
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
        // Nothing of another host's: a host with no terminal shows an empty canvas.
        let page = self.shown().and_then(|id| self.workspaces.containing(id));
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
        let area = BUTTONS.into_iter().fold(at(placed.terminal), |area, button| {
            area.on_mouse_down(
                button,
                cx.listener(move |this, event: &MouseDownEvent, window, cx| {
                    this.pointer_down(pane, button, event, window, cx);
                }),
            )
        });
        let cursor = match self.panes.get(&pane).map(|target| target.cursor()) {
            Some(Cursor::Arrow) => CursorStyle::Arrow,
            Some(Cursor::Hand) => CursorStyle::PointingHand,
            _ => CursorStyle::IBeam,
        };
        area.cursor(cursor)
            .on_mouse_move(cx.listener(move |this, event: &MouseMoveEvent, _, cx| {
                // Over a terminal with no press in progress: ⌘ points at links, and
                // a program that wants every move hears it.
                if this.pointer_pane.is_none()
                    && event.pressed_button.is_none()
                    && let Some(target) = this.panes.get_mut(&pane)
                {
                    let (x, y) = (f32::from(event.position.x), f32::from(event.position.y));
                    let before = target.cursor();
                    target.hover(x, y, event.modifiers.platform);
                    target.moved(x, y, false, press(event.modifiers, 0));
                    if target.cursor() != before {
                        cx.notify();
                    }
                }
            }))
            .on_scroll(cx.listener(move |this, event: &ScrollEvent, _, cx| {
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
            }))
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

    /// Where the input method's text arrives: the whole window while it has
    /// the keyboard, as the terminal's capture view is on a Mac.
    fn input_target(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let focus = self.focus.clone();
        let entity = cx.entity();
        canvas(
            |_, _, _| (),
            move |bounds, (), window, cx| {
                window.handle_input(&focus, ElementInputHandler::new(bounds, entity), cx);
            },
        )
        .absolute()
        .size_full()
    }

    /// A press on a terminal selects it, and the terminal takes the press.
    fn pointer_down(
        &mut self,
        pane: PaneId,
        button: MouseButton,
        event: &MouseDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.select(pane, cx);
        let Some(target) = self.panes.get_mut(&pane) else { return };
        let (x, y) = (f32::from(event.position.x), f32::from(event.position.y));
        let modifiers = event.modifiers;
        // ⌘ belongs to links: a program in the terminal cannot ask for it.
        if button == MouseButton::Left && modifiers.platform {
            if let Some(address) =
                target.link_at(x, y).as_ref().and_then(tether_desktop::links::web_address)
            {
                cx.open_url(address);
            }
            return;
        }
        // A right click is the menu, unless a program has the mouse and Shift is up.
        let program = target.tracking() != tether_ffi::MouseTracking::Off && !modifiers.shift;
        if button == MouseButton::Right && !program {
            let link = target.link_at(x, y);
            self.open_terminal_menu(pane, link, window, cx);
            return;
        }
        target.press(pointer_button(button), x, y, press(modifiers, event.click_count));
        self.pointer_pane = Some(pane);
    }

    /// The press ends wherever the pointer is; a drag that selected copies.
    fn pointer_up(&mut self, button: MouseButton, event: &MouseUpEvent, cx: &mut Context<Self>) {
        if button == MouseButton::Left {
            self.drag = None;
        }
        let Some(pane) = self.pointer_pane.take() else { return };
        let Some(target) = self.panes.get_mut(&pane) else { return };
        let (x, y) = (f32::from(event.position.x), f32::from(event.position.y));
        let modifiers = press(event.modifiers, event.click_count);
        if let Some(text) = target.release(pointer_button(button), x, y, modifiers) {
            cx.write_to_clipboard(ClipboardItem::new_string(text));
        }
    }

    fn drag_to(&mut self, event: &MouseMoveEvent, cx: &mut Context<Self>) {
        if self.drag.is_none() {
            if let Some(target) = self.pointer_pane.and_then(|pane| self.panes.get_mut(&pane)) {
                let (x, y) = (f32::from(event.position.x), f32::from(event.position.y));
                target.moved(x, y, event.pressed_button.is_some(), press(event.modifiers, 0));
            }
            return;
        }
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

fn pointer_button(button: MouseButton) -> PointerButton {
    match button {
        MouseButton::Right => PointerButton::Right,
        MouseButton::Middle => PointerButton::Middle,
        _ => PointerButton::Left,
    }
}

fn press(modifiers: Modifiers, clicks: usize) -> Press {
    Press { clicks, shift: modifiers.shift, alt: modifiers.alt, control: modifiers.control }
}

fn at(rect: Rect) -> gpui::Div {
    div().absolute().left(px(rect.x)).top(px(rect.y)).w(px(rect.width)).h(px(rect.height))
}
