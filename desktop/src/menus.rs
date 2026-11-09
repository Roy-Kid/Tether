//! The chip menu, opened by a right click on a chip or a second click on
//! the selected one (`handleTabClick`), and what its items do.

use gpui::{Context, Window};
use tether_desktop::split::PaneId;
use tether_desktop::tab_menu::{self, Choice, Terminals};

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
        false
    }
}

impl Desktop {
    pub(crate) fn open_tab_menu(
        &mut self,
        id: PaneId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let items = tab_menu::tab_menu(&self.workspaces, id, self);
        let entries: Vec<_> = items.iter().map(|(entry, _)| entry.clone()).collect();
        let choices: Vec<_> = items.into_iter().map(|(_, choice)| choice).collect();
        // Opened from a task, not this handler: the menu's tracking loop
        // delivers events while it runs, and GPUI is mid-dispatch here.
        cx.spawn_in(window, async move |this, cx| {
            let chosen =
                platform::menu(&entries).and_then(|index| choices.get(index).copied().flatten());
            let Some(choice) = chosen else { return };
            let _ = this.update_in(cx, |this, window, cx| this.choose(id, choice, window, cx));
        })
        .detach();
    }

    fn choose(&mut self, id: PaneId, choice: Choice, window: &mut Window, cx: &mut Context<Self>) {
        let page = self.workspaces.containing(id).map(|page| page.id);
        match choice {
            Choice::NewTerminal => {
                self.workspaces = self.workspaces.selecting(id);
                self.open(page, window, cx);
            }
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
            Choice::Rename => {}
            Choice::Close => self.request_close(id, window, cx),
        }
        self.sync(cx);
    }
}
