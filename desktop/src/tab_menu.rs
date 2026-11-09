//! A terminal chip's menu: the Mac `WorkspaceChrome.tabMenu`.
//!
//! New Terminal; the tab's terminals, the focused one checked; the four
//! splits and Join All Splits; Rename Terminal; Close Terminal. The
//! platform draws it as its own menu (`platform::menu`).

use crate::split::{Direction, PaneId};
use crate::workspaces::Workspaces;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Entry {
    Item { title: String, enabled: bool, checked: bool },
    Separator,
}

/// What a chosen item does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Choice {
    NewTerminal,
    Select(PaneId),
    Split(Direction),
    JoinSplits,
    Rename,
    Close,
}

/// What the menu needs to know about each terminal.
pub trait Terminals {
    /// The chip's title and the state's name: `ssh 1 — Connected`.
    fn menu_title(&self, id: PaneId) -> String;
    /// A split needs a live shell, or one on this machine.
    fn can_split(&self, id: PaneId) -> bool;
    /// Rename edits the chip in place; `false` until the chip can.
    fn can_rename(&self) -> bool;
}

/// The menu for the chip of `id`, with what each item does.
pub fn tab_menu(
    state: &Workspaces,
    id: PaneId,
    terminals: &impl Terminals,
) -> Vec<(Entry, Option<Choice>)> {
    let Some(page) = state.containing(id) else {
        return vec![item("Close Tab", true, false, Choice::Close)];
    };
    let terminal = if page.terminals.contains(&id) { id } else { page.focused };
    let can_split = terminals.can_split(terminal);
    let mut menu =
        vec![item("New Terminal", true, false, Choice::NewTerminal), (Entry::Separator, None)];
    menu.extend(page.terminals.iter().map(|other| {
        item(&terminals.menu_title(*other), true, page.focused == *other, Choice::Select(*other))
    }));
    menu.push((Entry::Separator, None));
    for (title, direction) in [
        ("Split Left", Direction::Left),
        ("Split Right", Direction::Right),
        ("Split Up", Direction::Up),
        ("Split Down", Direction::Down),
    ] {
        menu.push(item(title, can_split, false, Choice::Split(direction)));
    }
    menu.push(item("Join All Splits", page.layout.is_some(), false, Choice::JoinSplits));
    menu.push((Entry::Separator, None));
    menu.push(item("Rename Terminal", terminals.can_rename(), false, Choice::Rename));
    menu.push(item("Close Terminal", true, false, Choice::Close));
    menu
}

fn item(title: &str, enabled: bool, checked: bool, choice: Choice) -> (Entry, Option<Choice>) {
    (Entry::Item { title: title.to_owned(), enabled, checked }, Some(choice))
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

    fn titles(menu: &[(Entry, Option<Choice>)]) -> Vec<String> {
        menu.iter()
            .map(|(entry, _)| match entry {
                Entry::Item { title, enabled, checked } => {
                    format!(
                        "{title}{}{}",
                        if *checked { " ✓" } else { "" },
                        if *enabled { "" } else { " (off)" }
                    )
                }
                Entry::Separator => "—".to_owned(),
            })
            .collect()
    }

    #[test]
    fn the_menu_is_the_mac_tab_menu() {
        let state = Workspaces::default().adopting(PaneId(1), None).splitting(
            PaneId(1),
            PaneId(2),
            Direction::Right,
        );
        let menu = tab_menu(&state, PaneId(1), &Local);
        assert_eq!(
            titles(&menu),
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
        assert_eq!(menu[3].1, Some(Choice::Select(PaneId(2))));
    }

    #[test]
    fn join_is_off_without_a_split() {
        let state = Workspaces::default().adopting(PaneId(1), None);
        let menu = tab_menu(&state, PaneId(1), &Local);
        assert!(titles(&menu).contains(&"Join All Splits (off)".to_owned()));
    }
}
