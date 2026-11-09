//! GPUI paint of the chrome [`crate::layout`] produced.
//!
//! The drawing follows the Mac workspace: a content-sized tab chip, a 2pt
//! accent rule, the host bar, and the semantic colours the host passes in.
//! [`Role::Terminal`](crate::Role::Terminal), a plugin surface and the host's
//! traffic-light reserve stay empty. This view does not open a window.
//!
//! Clicks stay on the painted controls. The fixed hit map in [`crate::layout`]
//! is the geometry check; it is not what the pointer hits.
//!
//! The view does not own the workspace. A click is a [`ChromeEvent`]; the
//! host applies it to its model and hands the view the tabs it should show.
//! Only the host picker's open state is the view's own.

use gpui::{
    App, ClickEvent, Context, EventEmitter, FontWeight, IntoElement, MouseButton, Render,
    SharedString, Stateful, Window, div, prelude::*, px, rgb,
};

use std::sync::Arc;

use crate::icons::{Icon, Style, Symbols, icon};
use crate::{Chrome, Kind, Placement, Rect, Tab, Workspace, layout};

/// Ink the host supplies. Chrome follows the platform's semantic colours, so
/// this crate does not freeze a light or dark palette of its own.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Ink {
    pub text: u32,
    pub subtle: u32,
    pub separator: u32,
    pub accent: u32,
    pub surface: u32,
    pub presence: u32,
    pub text_alpha: f32,
    pub subtle_alpha: f32,
    pub separator_alpha: f32,
}

/// What a click on the chrome asks the host to do. Indices are into the
/// `tabs` and `hosts` the view was given.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChromeEvent {
    Select(usize),
    /// A right click on a chip: the host opens that terminal's menu.
    Menu(usize),
    Close(usize),
    NewTab,
    PickHost(usize),
    Settings,
}

/// The workspace chrome. Mount it in the window the host opened.
///
/// `hosts` is the list the host cluster shows. This crate does not read the
/// host library. `host_open` is the cluster's selected state, and the one
/// piece of state the view changes itself. `settings_open` is the gear's
/// selected state; the host opens its own settings window.
pub struct ChromeView {
    pub workspace: Workspace,
    pub tabs: Vec<Tab>,
    pub host: String,
    pub hosts: Vec<String>,
    pub host_open: bool,
    pub settings_open: bool,
    pub ink: Ink,
    /// The platform's symbols. `None` draws the bundled stand-ins.
    pub symbols: Option<Arc<dyn Symbols>>,
    /// The selected terminal's shell has ended: the status bar's mark.
    pub ended: bool,
}

impl EventEmitter<ChromeEvent> for ChromeView {}

impl ChromeView {
    /// Close the picker and tell the host. Every click but the cluster's own does this.
    fn send(&mut self, event: ChromeEvent, cx: &mut Context<Self>) {
        self.host_open = false;
        cx.emit(event);
        cx.notify();
    }
}

impl Render for ChromeView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let frame = layout(&self.workspace, &self.tabs);
        let ink = self.ink;
        let width = self.workspace.width;
        let show = self.workspace.tab_bar && !self.workspace.zen;
        let horizontal = show && self.workspace.placement == Placement::Horizontal;
        let top = frame.region(Kind::TabStrip).or_else(|| frame.region(Kind::DragStrip));
        let picker = self.host_open && !self.hosts.is_empty();
        div()
            .relative()
            .w(px(width))
            .h(px(self.workspace.height))
            .font_family(SYSTEM_FONT)
            .text_color(paint(ink.text, ink.text_alpha))
            .children(top.map(|strip| titlebar(self, strip.height, horizontal, cx)))
            .children(frame.region(Kind::TabSidebar).map(|column| sidebar(self, column, cx)))
            .children(
                frame
                    .regions_of(Kind::Divider)
                    .map(|rect| at(rect).bg(paint(ink.separator, ink.separator_alpha))),
            )
            .children(frame.region(Kind::Status).map(|rect| status(self, rect, cx)))
            .when(picker, |root| root.child(host_picker(self, cx)))
    }
}

fn titlebar(
    view: &ChromeView,
    height: f32,
    horizontal: bool,
    cx: &mut Context<ChromeView>,
) -> gpui::Div {
    let ink = view.ink;
    let width = view.workspace.width;
    let mut row = div()
        .absolute()
        .left(px(0.0))
        .top(px(0.0))
        .w(px(width))
        .h(px(height))
        .flex()
        .flex_row()
        .items_center()
        .child(div().flex_none().w(px(view.workspace.leading_reserve)).h(px(height)));
    if horizontal {
        row = row.child(tab_row(view, cx)).child(plus(view, Chrome::TAB, cx));
    }
    bar(0.0, width, height)
        .bg(paint(ink.surface, 1.0))
        .child(hairline(width, false, paint(ink.separator, ink.separator_alpha)))
        .child(row.child(drag_strip(height)))
}

fn sidebar(view: &ChromeView, column: Rect, cx: &mut Context<ChromeView>) -> gpui::Div {
    at(column)
        .bg(paint(view.ink.surface, 1.0))
        .flex()
        .flex_col()
        .children(chips(view, false, column.width, cx))
        .child(plus(view, Chrome::TAB_SIDEBAR_ROW, cx))
}

fn tab_row(view: &ChromeView, cx: &mut Context<ChromeView>) -> gpui::Div {
    let chips = chips(view, true, Chrome::TAB, cx);
    div()
        .flex()
        .flex_none()
        .flex_row()
        .items_center()
        .h(px(Chrome::TAB))
        .gap(px(Chrome::SPACE_SMALL))
        .children(chips)
}

fn chips(
    view: &ChromeView,
    horizontal: bool,
    span: f32,
    cx: &mut Context<ChromeView>,
) -> Vec<gpui::Div> {
    let count = view.tabs.len();
    let mut chips = Vec::with_capacity(count);
    for index in 0..count {
        let tab = view.tabs[index].clone();
        chips.push(chip(view, &tab, index, horizontal, span, cx));
    }
    chips
}

fn chip(
    view: &ChromeView,
    tab: &Tab,
    index: usize,
    horizontal: bool,
    span: f32,
    cx: &mut Context<ChromeView>,
) -> gpui::Div {
    let row = if horizontal { Chrome::TAB } else { Chrome::TAB_SIDEBAR_ROW };
    let mut chip = div()
        .group(chip_group(index))
        .relative()
        .flex()
        .flex_none()
        .flex_row()
        .items_center()
        .h(px(row))
        .gap(px(Chrome::SPACE_INLINE))
        .rounded(px(Chrome::ROW_RADIUS))
        .child(tab_face(view, tab, index, horizontal, cx))
        .child(close_slot(view, index, row, tab.selected, cx));
    chip = if horizontal {
        chip.pl(px(Chrome::SPACE_INSET)).pr(px(Chrome::SPACE_INSET))
    } else {
        chip.w(px(span)).pl(px(Chrome::SPACE_GROUP)).pr(px(Chrome::SPACE_SMALL))
    };
    chip.when(tab.selected, |chip| {
        chip.bg(rgb(view.ink.accent).opacity(Chrome::SELECTION_OPACITY))
            .child(rule(horizontal, view.ink))
    })
}

fn tab_face(
    view: &ChromeView,
    tab: &Tab,
    index: usize,
    horizontal: bool,
    cx: &mut Context<ChromeView>,
) -> Stateful<gpui::Div> {
    let color = if tab.selected { view.ink.text } else { view.ink.subtle };
    let alpha = if tab.selected { view.ink.text_alpha } else { view.ink.subtle_alpha };
    let row = if horizontal { Chrome::TAB } else { Chrome::TAB_SIDEBAR_ROW };
    let face = div()
        .id(("tab", index))
        .debug_selector(move || format!("tab-{index}"))
        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
            cx.stop_propagation();
            this.send(ChromeEvent::Select(index), cx);
        }))
        .on_mouse_down(
            MouseButton::Right,
            cx.listener(move |this, _: &gpui::MouseDownEvent, _, cx| {
                cx.stop_propagation();
                this.send(ChromeEvent::Menu(index), cx);
            }),
        )
        .flex()
        .flex_row()
        .items_center()
        .gap(px(Chrome::SPACE_INLINE))
        .h(px(row))
        .child(icon(view.symbols.as_deref(), Icon::Terminal, Style::Symbol, color, alpha));
    if horizontal {
        face.child(title_text(&tab.title, color, alpha, true))
    } else {
        face.flex_1().min_w(px(0.0)).child(title_text(&tab.title, color, alpha, false))
    }
}

fn title_text(title: &str, color: u32, alpha: f32, medium: bool) -> gpui::Div {
    let mut text = div()
        .min_w(px(0.0))
        .max_w(px(Chrome::TAB_TITLE_WIDTH))
        .truncate()
        .text_size(px(Chrome::TITLE))
        .line_height(px(TITLE_LINE))
        .text_color(paint(color, alpha))
        .child(title.to_owned());
    if medium {
        text = text.font_weight(FontWeight::MEDIUM);
    }
    text
}

/// The close box shows on the selected tab and on the one under the pointer,
/// the Mac rule. Hidden, it still holds its width so titles do not move.
fn close_slot(
    view: &ChromeView,
    index: usize,
    row: f32,
    selected: bool,
    cx: &mut Context<ChromeView>,
) -> Stateful<gpui::Div> {
    let ink = view.ink;
    let slot = div()
        .id(("close", index))
        .debug_selector(move || format!("close-{index}"))
        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
            cx.stop_propagation();
            if index < this.tabs.len() {
                this.send(ChromeEvent::Close(index), cx);
            }
        }))
        .flex()
        .flex_none()
        .items_center()
        .justify_center()
        .w(px(Chrome::ICON))
        .h(px(row))
        .rounded(px(Chrome::ROW_RADIUS))
        .hover(|style| style.bg(rgb(ink.text).opacity(HOVER_OPACITY)))
        .child(icon(
            view.symbols.as_deref(),
            Icon::Close,
            Style::TabClose,
            ink.subtle,
            ink.subtle_alpha,
        ));
    if selected {
        slot
    } else {
        slot.opacity(0.0).group_hover(chip_group(index), |style| style.opacity(1.0))
    }
}

fn chip_group(index: usize) -> SharedString {
    format!("chip-{index}").into()
}

fn rule(horizontal: bool, ink: Ink) -> gpui::Div {
    let accent = rgb(ink.accent);
    if horizontal {
        div().absolute().bottom(px(0.0)).left(px(0.0)).right(px(0.0)).h(px(Chrome::RULE)).bg(accent)
    } else {
        div().absolute().top(px(0.0)).bottom(px(0.0)).left(px(0.0)).w(px(Chrome::RULE)).bg(accent)
    }
}

fn plus(view: &ChromeView, row: f32, cx: &mut Context<ChromeView>) -> Stateful<gpui::Div> {
    let mut button = hit(
        "new-tab",
        "new-tab",
        false,
        view.ink,
        cx.listener(|this, _: &ClickEvent, _, cx| {
            cx.stop_propagation();
            this.send(ChromeEvent::NewTab, cx);
        }),
    )
    .flex()
    .flex_none()
    .items_center()
    .justify_center()
    .w(px(Chrome::TAB))
    .h(px(row));
    let ink = view.ink;
    button = button.child(icon(
        view.symbols.as_deref(),
        Icon::Plus,
        Style::Symbol,
        ink.subtle,
        ink.subtle_alpha,
    ));
    button
}

fn status(view: &ChromeView, rect: Rect, cx: &mut Context<ChromeView>) -> gpui::Div {
    let ink = view.ink;
    let mut row = div()
        .absolute()
        .left(px(0.0))
        .top(px(0.0))
        .w(px(rect.width))
        .h(px(rect.height))
        .flex()
        .flex_row()
        .items_center()
        .px(px(Chrome::SPACE_INSET))
        .child(host_button(view, rect.height, cx))
        .when(view.ended, |row| {
            row.child(icon(
                view.symbols.as_deref(),
                Icon::Ended,
                Style::Symbol,
                ink.subtle,
                ink.subtle_alpha,
            ))
        })
        .child(div().h(px(rect.height)).flex_1())
        .gap(px(Chrome::SPACE_GROUP));
    // Trailing: the inspector plugins' toggles, then Settings (`HostStatusBar`).
    // Inspector plugins arrive with the plugin kit.
    if view.workspace.settings {
        let open = view.settings_open;
        row = row.child(control(
            view,
            "settings",
            Icon::Settings,
            open,
            ChromeEvent::Settings,
            rect.height,
            cx,
        ));
    }
    bar(rect.y, rect.width, rect.height)
        .bg(paint(ink.surface, 1.0))
        .child(hairline(rect.width, true, paint(ink.separator, ink.separator_alpha)))
        .child(row)
}

fn host_button(
    view: &ChromeView,
    height: f32,
    cx: &mut Context<ChromeView>,
) -> Stateful<gpui::Div> {
    let ink = view.ink;
    let cluster = hit(
        "host",
        "host",
        view.host_open,
        ink,
        cx.listener(|this, _: &ClickEvent, _, cx| {
            cx.stop_propagation();
            this.host_open = !this.host_open;
            cx.notify();
        }),
    )
    .flex()
    .flex_none()
    .flex_row()
    .items_center()
    .gap(px(Chrome::SPACE_INLINE))
    .h(px(height))
    .px(px(Chrome::SPACE_SMALL));
    let cluster = if view.host.is_empty() {
        cluster
    } else {
        cluster
            .child(
                div()
                    .flex_none()
                    .w(px(Chrome::PRESENCE))
                    .h(px(Chrome::PRESENCE))
                    .rounded(px(Chrome::PRESENCE / 2.0))
                    .bg(rgb(ink.presence)),
            )
            .child(host_label(view))
    };
    cluster.child(icon(
        view.symbols.as_deref(),
        Icon::ChevronDown,
        Style::Accessory,
        ink.subtle,
        ink.subtle_alpha,
    ))
}

fn host_label(view: &ChromeView) -> gpui::Div {
    named(&view.ink, &view.host, Chrome::DETAIL, false, true)
}

fn host_picker(view: &ChromeView, cx: &mut Context<ChromeView>) -> gpui::Div {
    let ink = view.ink;
    let rows = view.hosts.iter().enumerate().map(|(index, name)| {
        let selected = name == &view.host;
        let mut row = hit(
            ("host-row", index),
            "host-row",
            selected,
            ink,
            cx.listener(move |this, _: &ClickEvent, _, cx| {
                cx.stop_propagation();
                this.send(ChromeEvent::PickHost(index), cx);
            }),
        )
        .h(px(Chrome::TAB))
        .px(px(Chrome::SPACE_INSET))
        .flex()
        .items_center();
        row = row.child(named(&ink, name, Chrome::DETAIL, false, true));
        row
    });
    // `UIStyle.pickerWidth`. Sits on the terminal hole, just above the host bar.
    div()
        .absolute()
        .left(px(Chrome::SPACE_INSET))
        .bottom(px(Chrome::STATUS + Chrome::SPACE_SMALL))
        .w(px(PICKER_WIDTH))
        .p(px(Chrome::HAIRLINE))
        .rounded(px(Chrome::ROW_RADIUS))
        .bg(paint(ink.separator, ink.separator_alpha))
        .child(
            div()
                .bg(paint(ink.surface, 1.0))
                .rounded(px(Chrome::ROW_RADIUS))
                .p(px(Chrome::SPACE_SMALL))
                .flex()
                .flex_col()
                .children(rows),
        )
}

/// An icon button on the status bar. It sends `event`; the host acts.
fn control(
    view: &ChromeView,
    id: &'static str,
    symbol: Icon,
    selected: bool,
    event: ChromeEvent,
    height: f32,
    cx: &mut Context<ChromeView>,
) -> Stateful<gpui::Div> {
    let ink = view.ink;
    hit(
        id,
        id,
        selected,
        ink,
        cx.listener(move |this, _: &ClickEvent, _, cx| {
            cx.stop_propagation();
            this.send(event, cx);
        }),
    )
    .flex()
    .flex_none()
    .items_center()
    .justify_center()
    .w(px(Chrome::ICON))
    .h(px(height))
    .child(icon(view.symbols.as_deref(), symbol, Style::Symbol, ink.subtle, ink.subtle_alpha))
}

/// A chrome control. Selected uses the accent wash. Otherwise the pointer
/// washes the label colour, matching `ChromeButtonStyle`.
fn hit(
    id: impl Into<gpui::ElementId>,
    selector: &'static str,
    selected: bool,
    ink: Ink,
    click: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
) -> Stateful<gpui::Div> {
    let mut el = div()
        .id(id)
        .debug_selector(move || selector.to_owned())
        .on_click(click)
        .rounded(px(Chrome::ROW_RADIUS));
    if selected {
        el = el.bg(rgb(ink.accent).opacity(Chrome::SELECTION_OPACITY));
    } else {
        el = el.hover(|style| style.bg(rgb(ink.text).opacity(HOVER_OPACITY)));
    }
    el
}

/// Empty titlebar, to the right of the chips. The window moves from here.
fn drag_strip(height: f32) -> Stateful<gpui::Div> {
    div()
        .id("titlebar-drag")
        .debug_selector(|| "titlebar-drag".to_owned())
        .h(px(height))
        .flex_1()
        .on_mouse_down(MouseButton::Left, |_, window, _| {
            window.start_window_move();
        })
}

fn named(ink: &Ink, text: &str, size: f32, medium: bool, bright: bool) -> gpui::Div {
    let mut label = div()
        .flex_none()
        .text_size(px(size))
        .line_height(px(if size >= Chrome::TITLE { TITLE_LINE } else { DETAIL_LINE }))
        .text_color(paint(ink.text, if bright { ink.text_alpha } else { ink.subtle_alpha }))
        .child(text.to_owned());
    if medium {
        label = label.font_weight(FontWeight::MEDIUM);
    }
    label
}

fn at(rect: Rect) -> gpui::Div {
    div().absolute().left(px(rect.x)).top(px(rect.y)).w(px(rect.width)).h(px(rect.height))
}

fn bar(y: f32, width: f32, height: f32) -> gpui::Div {
    div().absolute().left(px(0.0)).top(px(y)).w(px(width)).h(px(height))
}

fn hairline(width: f32, top: bool, color: gpui::Rgba) -> gpui::Div {
    let mut line = div().absolute().left(px(0.0)).w(px(width)).h(px(Chrome::HAIRLINE)).bg(color);
    line = if top { line.top(px(0.0)) } else { line.bottom(px(0.0)) };
    line
}

fn paint(color: u32, alpha: f32) -> gpui::Rgba {
    rgb(color).opacity(alpha)
}

const TITLE_LINE: f32 = 16.0;
const DETAIL_LINE: f32 = 14.0;
/// `UIStyle.hoverOpacity`.
const HOVER_OPACITY: f32 = 0.06;
/// `UIStyle.pickerWidth`.
const PICKER_WIDTH: f32 = 280.0;
/// GPUI's portable name for the platform UI font: SF on a Mac, Segoe on Windows.
const SYSTEM_FONT: &str = ".SystemUIFont";

#[cfg(all(test, feature = "test-support"))]
mod clicks {
    use std::cell::RefCell;
    use std::rc::Rc;

    use gpui::{Modifiers, TestAppContext, px, size};

    use super::*;

    fn sample() -> ChromeView {
        ChromeView {
            workspace: Workspace::mac(Chrome::WINDOW_WIDTH, Chrome::WINDOW_HEIGHT),
            tabs: vec![Tab::new("localhost").selected(), Tab::new("zsh")],
            host: "localhost".to_owned(),
            hosts: vec!["localhost".to_owned()],
            host_open: false,
            settings_open: false,
            ink: Ink {
                text: 0xFFFFFF,
                subtle: 0xFFFFFF,
                separator: 0xFFFFFF,
                accent: 0x007AFF,
                surface: 0x1E1E1E,
                presence: 0x30D158,
                text_alpha: 0.85,
                subtle_alpha: 0.55,
                separator_alpha: 0.10,
            },
            symbols: None,
            ended: false,
        }
    }

    fn click(cx: &mut gpui::VisualTestContext, selector: &'static str) {
        let bounds = cx.debug_bounds(selector).unwrap_or_else(|| panic!("missing {selector}"));
        cx.simulate_click(bounds.center(), Modifiers::default());
        cx.run_until_parked();
    }

    #[gpui::test]
    fn chrome_clicks_are_events_for_the_host(cx: &mut TestAppContext) {
        let (view, cx) = cx.add_window_view(|_, _| sample());
        cx.simulate_resize(size(px(Chrome::WINDOW_WIDTH), px(Chrome::WINDOW_HEIGHT)));
        cx.run_until_parked();
        let seen = Rc::new(RefCell::new(Vec::new()));
        let sink = seen.clone();
        cx.update(|_, cx| {
            cx.subscribe(&view, move |_, event: &ChromeEvent, _| sink.borrow_mut().push(*event))
                .detach();
        });

        let tab = cx.debug_bounds("tab-1").expect("tab");
        let drag = cx.debug_bounds("titlebar-drag").expect("drag");
        assert!(drag.origin.x >= tab.origin.x + tab.size.width, "drag {drag:?} covers tab {tab:?}");

        click(cx, "tab-1");
        click(cx, "new-tab");
        // An unselected tab's close box is hidden until hovered, and still closes.
        click(cx, "close-1");
        click(cx, "close-0");
        click(cx, "host");
        cx.update(|_, cx| assert!(view.read(cx).host_open));
        click(cx, "host-row");
        cx.update(|_, cx| assert!(!view.read(cx).host_open));
        click(cx, "settings");

        assert_eq!(
            *seen.borrow(),
            [
                ChromeEvent::Select(1),
                ChromeEvent::NewTab,
                ChromeEvent::Close(1),
                ChromeEvent::Close(0),
                ChromeEvent::PickHost(0),
                ChromeEvent::Settings,
            ]
        );
        // The view changed nothing the host owns.
        cx.update(|_, cx| {
            let view = view.read(cx);
            assert_eq!(view.tabs, sample().tabs);
            assert!(!view.settings_open);
        });
    }
}
