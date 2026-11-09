//! The menus a terminal has, as the Mac app builds them.
//!
//! A chip's (`WorkspaceChrome.tabMenu`): New Terminal; the tab's terminals,
//! the focused one checked; the four splits and Join All Splits; Rename
//! Terminal; Close Terminal. The terminal's own, on a right click
//! (`TabSet.terminalMenu`, `KeyCaptureView.menu`): Switch Terminal; New
//! Terminal and New Tab; the splits; Rename and Close; and, over a link,
//! what the link offers. The platform draws them (`platform::menu`).

use crate::split::{Direction, PaneId};
use crate::workspaces::Workspaces;

/// What a chosen item does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Choice {
    NewTerminal,
    NewTab,
    Select(PaneId),
    Split(Direction),
    JoinSplits,
    Rename,
    Close,
    OpenLink,
    CopyLink,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Entry {
    /// `choice` is the index the platform answers with.
    Item {
        title: String,
        enabled: bool,
        checked: bool,
        choice: usize,
    },
    Submenu {
        title: String,
        entries: Vec<Entry>,
    },
    Separator,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Menu {
    pub entries: Vec<Entry>,
    choices: Vec<Choice>,
}

impl Menu {
    /// What the item the platform answered with does.
    pub fn choice(&self, answered: usize) -> Option<Choice> {
        self.choices.get(answered).copied()
    }

    fn item(&mut self, title: &str, enabled: bool, checked: bool, choice: Choice) -> Entry {
        self.choices.push(choice);
        Entry::Item { title: title.to_owned(), enabled, checked, choice: self.choices.len() - 1 }
    }

    fn push(&mut self, title: &str, enabled: bool, choice: Choice) {
        let entry = self.item(title, enabled, false, choice);
        self.entries.push(entry);
    }

    fn terminals(
        &mut self,
        state: &Workspaces,
        id: PaneId,
        terminals: &impl Terminals,
    ) -> Vec<Entry> {
        let Some(page) = state.containing(id) else { return Vec::new() };
        page.terminals
            .iter()
            .map(|other| {
                self.item(
                    &terminals.menu_title(*other),
                    true,
                    page.focused == *other,
                    Choice::Select(*other),
                )
            })
            .collect()
    }

    fn splits(&mut self, state: &Workspaces, id: PaneId, terminals: &impl Terminals) {
        let can_split = terminals.can_split(id);
        for (title, direction) in [
            ("Split Left", Direction::Left),
            ("Split Right", Direction::Right),
            ("Split Up", Direction::Up),
            ("Split Down", Direction::Down),
        ] {
            self.push(title, can_split, Choice::Split(direction));
        }
        let joined = state.containing(id).is_none_or(|page| page.layout.is_none());
        self.push("Join All Splits", !joined, Choice::JoinSplits);
    }
}

/// What the menus need to know about each terminal.
pub trait Terminals {
    /// The chip's title and the state's name: `ssh 1 — Connected`.
    fn menu_title(&self, id: PaneId) -> String;
    /// A split needs a live shell, or one on this machine.
    fn can_split(&self, id: PaneId) -> bool;
    /// Rename edits the chip in place; `false` until the chip can.
    fn can_rename(&self) -> bool;
}

/// The chip of `id`.
pub fn tab_menu(state: &Workspaces, id: PaneId, terminals: &impl Terminals) -> Menu {
    let mut menu = Menu::default();
    let Some(page) = state.containing(id) else {
        menu.push("Close Tab", true, Choice::Close);
        return menu;
    };
    let terminal = if page.terminals.contains(&id) { id } else { page.focused };
    menu.push("New Terminal", true, Choice::NewTerminal);
    menu.entries.push(Entry::Separator);
    let list = menu.terminals(state, terminal, terminals);
    menu.entries.extend(list);
    menu.entries.push(Entry::Separator);
    menu.splits(state, terminal, terminals);
    menu.entries.push(Entry::Separator);
    menu.push("Rename Terminal", terminals.can_rename(), Choice::Rename);
    menu.push("Close Terminal", true, Choice::Close);
    menu
}

/// The terminal's own menu. `link` is whether a web link is under the pointer.
pub fn terminal_menu(
    state: &Workspaces,
    id: PaneId,
    terminals: &impl Terminals,
    link: bool,
) -> Menu {
    let mut menu = Menu::default();
    if state.containing(id).is_none() {
        return menu;
    }
    let list = menu.terminals(state, id, terminals);
    menu.entries.push(Entry::Submenu { title: "Switch Terminal".into(), entries: list });
    menu.entries.push(Entry::Separator);
    menu.push("New Terminal", true, Choice::NewTerminal);
    menu.push("New Tab", true, Choice::NewTab);
    menu.splits(state, id, terminals);
    menu.entries.push(Entry::Separator);
    menu.push("Rename Terminal", terminals.can_rename(), Choice::Rename);
    menu.push("Close Terminal", true, Choice::Close);
    if link {
        menu.entries.push(Entry::Separator);
        menu.push("Open Link", true, Choice::OpenLink);
        menu.push("Copy", true, Choice::CopyLink);
    }
    menu
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Local;

    impl Terminals for Local {
        fn menu_title(&self, id: PaneId) -> String {
            format!("Terminal {} — Connected", id.0)
        }
        fn can_split(&self, _: PaneId) -> bool {
            true
        }
        fn can_rename(&self) -> bool {
            false
        }
    }

    fn titles(entries: &[Entry]) -> Vec<String> {
        entries
            .iter()
            .map(|entry| match entry {
                Entry::Item { title, enabled, checked, .. } => {
                    format!(
                        "{title}{}{}",
                        if *checked { " ✓" } else { "" },
                        if *enabled { "" } else { " (off)" }
                    )
                }
                Entry::Submenu { title, entries } => {
                    format!("{title} ▸ {}", titles(entries).join(", "))
                }
                Entry::Separator => "—".to_owned(),
            })
            .collect()
    }

    fn split() -> Workspaces {
        Workspaces::default().adopting(PaneId(1), None).splitting(
            PaneId(1),
            PaneId(2),
            Direction::Right,
        )
    }

    #[test]
    fn the_chip_menu_is_the_mac_tab_menu() {
        let menu = tab_menu(&split(), PaneId(1), &Local);
        assert_eq!(
            titles(&menu.entries),
            [
                "New Terminal",
                "—",
                "Terminal 1 — Connected",
                "Terminal 2 — Connected ✓",
                "—",
                "Split Left",
                "Split Right",
                "Split Up",
                "Split Down",
                "Join All Splits",
                "—",
                "Rename Terminal (off)",
                "Close Terminal",
            ]
        );
        let Entry::Item { choice, .. } = menu.entries[3] else { panic!() };
        assert_eq!(menu.choice(choice), Some(Choice::Select(PaneId(2))));
    }

    #[test]
    fn the_terminal_menu_is_the_mac_terminal_menu_and_a_link_adds_its_own() {
        let menu = terminal_menu(&split(), PaneId(2), &Local, true);
        assert_eq!(
            titles(&menu.entries),
            [
                "Switch Terminal ▸ Terminal 1 — Connected, Terminal 2 — Connected ✓",
                "—",
                "New Terminal",
                "New Tab",
                "Split Left",
                "Split Right",
                "Split Up",
                "Split Down",
                "Join All Splits",
                "—",
                "Rename Terminal (off)",
                "Close Terminal",
                "—",
                "Open Link",
                "Copy",
            ]
        );
        assert!(
            !titles(&terminal_menu(&split(), PaneId(2), &Local, false).entries)
                .contains(&"Open Link".to_owned())
        );
    }

    #[test]
    fn join_is_off_without_a_split() {
        let state = Workspaces::default().adopting(PaneId(1), None);
        assert!(
            titles(&tab_menu(&state, PaneId(1), &Local).entries)
                .contains(&"Join All Splits (off)".to_owned())
        );
    }
}
