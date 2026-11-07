use gpui::{
    Context, Entity, FocusHandle, IntoElement, KeyDownEvent, MouseButton, ParentElement, Render,
    Styled, Window, div, prelude::*, px, rgb,
};

use crate::chrome::{self, ChromeMetrics, DesktopOs};
use crate::workspace::{Session, ThemeChoice};

use super::tabs::plain_titlebar;
use super::workspace_view::system_dark;

pub struct SettingsView {
    session: Entity<Session>,
    focus: FocusHandle,
    query: String,
}

impl SettingsView {
    pub fn new(session: Entity<Session>, cx: &mut Context<Self>) -> Self {
        cx.observe(&session, |_, _, cx| cx.notify()).detach();
        Self { session, focus: cx.focus_handle(), query: String::new() }
    }

    pub(crate) fn focus_handle(&self) -> FocusHandle {
        self.focus.clone()
    }

    fn on_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let key = event.keystroke.key.as_str();
        if key == "backspace" {
            self.query.pop();
            cx.notify();
            return;
        }
        if key == "escape" {
            window.remove_window();
            return;
        }
        let modifiers = event.keystroke.modifiers;
        if modifiers.control || modifiers.alt || modifiers.platform || modifiers.function {
            return;
        }
        if let Some(text) = event.keystroke.key_char.as_deref()
            && text.chars().count() == 1
        {
            let ch = text.chars().next().unwrap();
            if !ch.is_control() {
                self.query.push(ch);
                cx.notify();
            }
        }
    }
}

impl Render for SettingsView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = self.session.read(cx).theme;
        let colors = chrome::colors(theme, system_dark(window));
        let metrics = ChromeMetrics::for_os(DesktopOs::current());
        let choices = [
            (ThemeChoice::System, "System"),
            (ThemeChoice::Dark, "Dark"),
            (ThemeChoice::Light, "Light"),
        ];
        let query = self.query.to_lowercase();
        let mut rows = Vec::new();
        for (choice, name) in choices {
            if !query.is_empty() && !name.to_lowercase().contains(query.trim()) {
                continue;
            }
            let selected = theme == choice;
            rows.push(
                div()
                    .h(px(28.))
                    .px(px(chrome::GROUP))
                    .flex()
                    .items_center()
                    .rounded(px(chrome::ROW_RADIUS))
                    .cursor_pointer()
                    .when(selected, |this| this.bg(rgb(colors.raised)))
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(move |this, _, _, cx| {
                            this.session.update(cx, |session, cx| {
                                session.theme = choice;
                                cx.notify();
                            });
                        }),
                    )
                    .child(name),
            );
        }
        let query = self.query.clone();
        let on_key = cx.listener(Self::on_key);
        let viewport = window.viewport_size();
        let mut root = div()
            .w(viewport.width)
            .h(viewport.height)
            .overflow_hidden()
            .flex()
            .flex_col()
            .bg(rgb(colors.window))
            .text_color(rgb(colors.text))
            .text_size(px(chrome::TITLE));
        if let Some(font) = metrics.ui_font {
            root = root.font_family(font);
        }
        root.child(plain_titlebar(colors, metrics, window.is_maximized())).child(
            div()
                .flex_grow(1.)
                .min_h(px(0.))
                .flex()
                .flex_col()
                .gap(px(chrome::SMALL))
                .p(px(chrome::SECTION))
                .child(
                    div()
                        .text_size(px(chrome::HEADER))
                        .text_color(rgb(colors.secondary))
                        .child("APPEARANCE"),
                )
                .child(
                    div()
                        .h(px(32.))
                        .px(px(chrome::GROUP))
                        .flex()
                        .items_center()
                        .rounded(px(chrome::ROW_RADIUS))
                        .bg(rgb(colors.chrome))
                        .text_size(px(chrome::INPUT))
                        .track_focus(&self.focus)
                        .on_key_down(on_key)
                        .child(if query.is_empty() { " ".into() } else { query }),
                )
                .children(rows),
        )
    }
}
