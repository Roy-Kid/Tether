//! The two menus a terminal has, opened as the Mac app opens them, and what
//! their items do. A chip's: a right click, or a second click on the
//! selected chip (`handleTabClick`). The terminal's: a right click on it
//! when no program has the mouse, or with Shift (`KeyCaptureView.menu`).

use gpui::{ClipboardItem, Context, Window};
use tether_desktop::links;
use tether_desktop::split::PaneId;
use tether_desktop::tab_menu::{self, Choice, Menu, Terminals};
use tether_ffi::TerminalLink;

use crate::platform;
use crate::workspace::Desktop;

impl Terminals for Desktop {
    fn menu_title(&self, id: PaneId) -> String {
        let state = if self.ended.contains(&id) {
            "Ended"
        } else if self.panes.contains_key(&id) {
            "Connected"
        } else {
            "Connecting"
        };
        format!("{} — {state}", self.titles.get(&id).cloned().unwrap_or_default())
    }

    /// Every terminal here is on this machine.
    fn can_split(&self, _: PaneId) -> bool {
        true
    }

    fn can_rename(&self) -> bool {
        true
    }
}

impl Desktop {
    pub(crate) fn open_tab_menu(
        &mut self,
        id: PaneId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let menu = tab_menu::tab_menu(&self.workspaces, id, self);
        self.show_menu(menu, id, None, window, cx);
    }

    /// `link` is the link under the pointer; only a web link adds its items.
    pub(crate) fn open_terminal_menu(
        &mut self,
        id: PaneId,
        link: Option<TerminalLink>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let link = link.filter(|link| links::web_address(link).is_some());
        let menu = tab_menu::terminal_menu(&self.workspaces, id, self, link.is_some());
        self.show_menu(menu, id, link, window, cx);
    }

    fn show_menu(
        &mut self,
        menu: Menu,
        id: PaneId,
        link: Option<TerminalLink>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // Opened from a task, not this handler: the menu's tracking loop
        // delivers events while it runs, and GPUI is mid-dispatch here.
        cx.spawn_in(window, async move |this, cx| {
            let Some(choice) = platform::menu(&menu.entries).and_then(|answer| menu.choice(answer))
            else {
                return;
            };
            let _ = this.update_in(cx, |this, window, cx| {
                this.choose(id, choice, link.as_ref(), window, cx)
            });
        })
        .detach();
    }

    fn choose(
        &mut self,
        id: PaneId,
        choice: Choice,
        link: Option<&TerminalLink>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let page = self.workspaces.containing(id).map(|page| page.id);
        match choice {
            Choice::NewTerminal => {
                self.workspaces = self.workspaces.selecting(id);
                self.open(page, window, cx);
            }
            Choice::NewTab => self.open(None, window, cx),
            Choice::Select(other) => self.workspaces = self.workspaces.selecting(other),
            Choice::Split(direction) => {
                self.workspaces = self.workspaces.selecting(id);
                self.split(direction, window, cx);
            }
            Choice::JoinSplits => {
                if let Some(page) = page {
                    self.workspaces = self.workspaces.joining(page);
                }
            }
            Choice::Rename => self.begin_rename(id, window, cx),
            Choice::Close => self.request_close(id, window, cx),
            Choice::OpenLink => {
                if let Some(address) = link.and_then(links::web_address) {
                    cx.open_url(address);
                }
            }
            Choice::CopyLink => {
                if let Some(link) = link {
                    cx.write_to_clipboard(ClipboardItem::new_string(link.text.clone()));
                }
            }
        }
        self.sync(cx);
    }
}
