use gpui::{
    Context, Entity, FocusHandle, IntoElement, Render, Window, WindowAppearance, div, prelude::*,
    px, rgb,
};

use crate::chrome::{self, ChromeMetrics, DesktopOs};
use crate::terminal::{self, HostCommand, TerminalHost};
use crate::workspace::{Command, CommandEffect, Session, TabId};

use super::dialogs::dialog;
use super::palette::palette;
use super::settings::SettingsView;
use super::split_view::{self, split_tree};
use super::status::status_bar;
use super::{CloseTab, NewTab, NextTab, OpenPalette, PreviousTab, SplitDown, SplitRight, Wake};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Hover {
    NewTab,
    SplitRight,
    SplitDown,
    Commands,
    Settings,
    Host(usize),
    TabClose(TabId),
}

pub struct WorkspaceView {
    pub(crate) session: Entity<Session>,
    pub(crate) focus: FocusHandle,
    pub(crate) palette_focus: FocusHandle,
    pub(crate) dialog_focus: FocusHandle,
    pub(crate) hover: Option<Hover>,
    pub(crate) terminal: TerminalHost,
}

impl WorkspaceView {
    pub fn new(session: Entity<Session>, cx: &mut Context<Self>) -> Self {
        cx.observe(&session, |_, _, cx| cx.notify()).detach();
        Self {
            session,
            focus: cx.focus_handle(),
            palette_focus: cx.focus_handle(),
            dialog_focus: cx.focus_handle(),
            hover: None,
            terminal: terminal::host(),
        }
    }

    pub(crate) fn focus_handle(&self) -> FocusHandle {
        self.focus.clone()
    }

    pub(crate) fn note_hover(&mut self, hover: Option<Hover>, cx: &mut Context<Self>) {
        if self.hover != hover {
            self.hover = hover;
            cx.notify();
        }
    }

    fn apply_commands(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.apply_list(terminal::take_commands(), window, cx);
    }

    fn apply_list(
        &mut self,
        commands: Vec<HostCommand>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        for command in commands {
            match command {
                HostCommand::Workspace(command) => self.shortcut(command, window, cx),
                HostCommand::Palette => self.open_palette(window, cx),
            }
        }
    }

    pub(crate) fn shortcut(
        &mut self,
        command: Command,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let effect = self.session.update(cx, |session, cx| {
            let effect = session.workspace_shortcut(command);
            cx.notify();
            effect
        });
        self.finish(effect, window, cx);
    }

    pub(crate) fn run(&mut self, command: Command, window: &mut Window, cx: &mut Context<Self>) {
        let effect = self.session.update(cx, |session, cx| {
            let effect = session.run_command(command);
            cx.notify();
            effect
        });
        self.finish(effect, window, cx);
    }

    pub(crate) fn close_tab(&mut self, id: TabId, window: &mut Window, cx: &mut Context<Self>) {
        let effect = self.session.update(cx, |session, cx| {
            let effect = session.request_close(id);
            cx.notify();
            effect
        });
        self.finish(effect, window, cx);
    }

    pub(crate) fn confirm(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let effect = self.session.update(cx, |session, cx| {
            let effect = session.confirm_close();
            cx.notify();
            effect
        });
        self.finish(effect, window, cx);
    }

    pub(crate) fn cancel_dialog(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.session.update(cx, |session, cx| {
            session.cancel_close();
            cx.notify();
        });
        self.focus.focus(window, cx);
    }

    pub(crate) fn open_palette(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.session.update(cx, |session, cx| {
            if session.palette_open {
                session.close_palette();
            } else if session.accept_workspace_shortcut() {
                session.open_palette();
            }
            cx.notify();
        });
        self.focus_current(window, cx);
    }

    pub(crate) fn on_palette_key(
        &mut self,
        event: &gpui::KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let key = event.keystroke.key.as_str();
        if key == "escape" {
            self.session.update(cx, |session, cx| {
                session.close_palette();
                cx.notify();
            });
            self.focus.focus(window, cx);
            return;
        }
        if key == "backspace" {
            self.session.update(cx, |session, cx| {
                session.palette_backspace();
                cx.notify();
            });
            return;
        }
        if key == "enter" {
            let command = {
                let session = self.session.read(cx);
                crate::workspace::matching_commands(&session.palette_query)
                    .get(session.palette_index)
                    .copied()
            };
            if let Some(command) = command {
                self.run(command, window, cx);
            }
            return;
        }
        if key == "up" {
            self.session.update(cx, |session, cx| {
                session.move_palette(-1);
                cx.notify();
            });
            return;
        }
        if key == "down" {
            self.session.update(cx, |session, cx| {
                session.move_palette(1);
                cx.notify();
            });
            return;
        }
        let modifiers = event.keystroke.modifiers;
        if modifiers.control || modifiers.alt || modifiers.platform || modifiers.function {
            return;
        }
        let Some(text) = event.keystroke.key_char.as_deref() else {
            return;
        };
        if text.chars().count() == 1 {
            let ch = text.chars().next().unwrap();
            if !ch.is_control() {
                self.session.update(cx, |session, cx| {
                    session.palette_push(ch);
                    cx.notify();
                });
            }
        }
    }

    fn finish(&mut self, effect: CommandEffect, window: &mut Window, cx: &mut Context<Self>) {
        match effect {
            CommandEffect::Quit => cx.quit(),
            CommandEffect::OpenSettings => self.open_settings(cx),
            CommandEffect::None | CommandEffect::Ignored => self.focus_current(window, cx),
        }
    }

    fn focus_current(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let session = self.session.read(cx);
        if session.model.pending().is_some() {
            self.dialog_focus.focus(window, cx);
        } else if session.palette_open {
            self.palette_focus.focus(window, cx);
        } else {
            self.focus.focus(window, cx);
        }
    }

    fn open_settings(&mut self, cx: &mut Context<Self>) {
        let session = self.session.clone();
        let bounds = gpui::Bounds::centered(None, gpui::size(px(420.), px(420.)), cx);
        cx.open_window(super::desktop_window("Settings", bounds, None), |window, cx| {
            window.set_window_title("Settings");
            let view = cx.new(|cx| SettingsView::new(session, cx));
            view.read(cx).focus_handle().focus(window, cx);
            view
        })
        .ok();
    }
}

impl Render for WorkspaceView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let snapshot = self.session.read(cx).clone();
        // A chord that arrives while this window is idle is applied by the
        // F24 binding. This drain covers a chord that lands in the same frame.
        let commands = terminal::take_commands();
        if !commands.is_empty() {
            cx.defer_in(window, move |this, window, cx| {
                this.apply_list(commands, window, cx);
            });
        }
        let colors = chrome::colors(snapshot.theme, system_dark(window));
        let metrics = ChromeMetrics::for_os(DesktopOs::current());
        let locals = snapshot.model.local_ids();
        let focused_local = snapshot.model.focused_local();
        self.terminal.sync(&locals, focused_local);
        // A non-local tab does not borrow the local shell. The child is also
        // hidden while a GPUI overlay is open, because it composites above it.
        let show_terminal = focused_local.is_some()
            && !snapshot.palette_open
            && snapshot.model.pending().is_none()
            && !snapshot.host_picker_open;
        let on_new = cx.listener(|this, _: &NewTab, window, cx| {
            this.shortcut(Command::NewTab, window, cx);
        });
        let on_close = cx.listener(|this, _: &CloseTab, window, cx| {
            this.shortcut(Command::CloseTab, window, cx);
        });
        let on_previous = cx.listener(|this, _: &PreviousTab, window, cx| {
            this.shortcut(Command::PreviousTab, window, cx);
        });
        let on_next = cx.listener(|this, _: &NextTab, window, cx| {
            this.shortcut(Command::NextTab, window, cx);
        });
        let on_palette = cx.listener(|this, _: &OpenPalette, window, cx| {
            this.open_palette(window, cx);
        });
        let on_right = cx.listener(|this, _: &SplitRight, window, cx| {
            this.shortcut(Command::SplitRight, window, cx);
        });
        let on_down = cx.listener(|this, _: &SplitDown, window, cx| {
            this.shortcut(Command::SplitDown, window, cx);
        });
        let on_wake = cx.listener(|this, _: &Wake, window, cx| {
            this.apply_commands(window, cx);
        });
        let tree = split_tree(
            self,
            &snapshot,
            split_view::TerminalPane {
                maximized: window.is_maximized(),
                show: show_terminal,
                dark: snapshot.theme.is_dark(system_dark(window)),
            },
            colors,
            metrics,
            cx,
        );
        let bar = status_bar(self, &snapshot, colors, metrics, cx);
        let palette_layer = snapshot.palette_open.then(|| palette(self, &snapshot, colors, cx));
        let dialog_layer = snapshot.model.pending().is_some().then(|| dialog(self, colors, cx));
        let viewport = window.viewport_size();
        div()
            .w(viewport.width)
            .h(viewport.height)
            .overflow_hidden()
            .flex()
            .flex_col()
            .bg(rgb(colors.window))
            .text_color(rgb(colors.text))
            .text_size(px(chrome::TITLE))
            .when_some(metrics.ui_font, |this, font| this.font_family(font))
            .relative()
            .child(
                div()
                    .flex_grow(1.)
                    .min_h(px(0.))
                    .w_full()
                    .flex()
                    .flex_col()
                    .overflow_hidden()
                    .key_context("Workspace")
                    .track_focus(&self.focus)
                    .on_action(on_new)
                    .on_action(on_close)
                    .on_action(on_previous)
                    .on_action(on_next)
                    .on_action(on_palette)
                    .on_action(on_right)
                    .on_action(on_down)
                    .on_action(on_wake)
                    .child(tree)
                    .child(bar),
            )
            .children(palette_layer)
            .children(dialog_layer)
    }
}

pub(crate) fn system_dark(window: &Window) -> bool {
    matches!(window.appearance(), WindowAppearance::Dark | WindowAppearance::VibrantDark)
}
