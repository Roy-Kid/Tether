//! Terminals and the tabs that lay them out: the Mac `TabSet`.
//!
//! The strip has one chip per terminal. A workspace (a tab page) holds
//! terminals in the order they joined and, when it is split, the layout of
//! the ones on screen. `selected` is a terminal; selecting one shows its
//! workspace with that terminal focused. Every change returns a new value.

use crate::split::{Direction, PaneId, Split};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct WorkspaceId(u64);

#[derive(Clone, Debug, PartialEq)]
pub struct Workspace {
    pub id: WorkspaceId,
    pub terminals: Vec<PaneId>,
    pub focused: PaneId,
    /// `None` shows the focused terminal alone.
    pub layout: Option<Split>,
}

impl Workspace {
    /// What is on screen.
    pub fn visible(&self) -> Split {
        self.layout.clone().unwrap_or(Split::Pane(self.focused))
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Workspaces {
    pages: Vec<Workspace>,
    selected: Option<PaneId>,
    next: u64,
}

impl Workspaces {
    pub fn pages(&self) -> &[Workspace] {
        &self.pages
    }

    pub fn selected(&self) -> Option<PaneId> {
        self.selected
    }

    /// Every terminal, in strip order.
    pub fn strip(&self) -> Vec<PaneId> {
        self.pages.iter().flat_map(|page| page.terminals.iter().copied()).collect()
    }

    pub fn containing(&self, id: PaneId) -> Option<&Workspace> {
        self.pages.iter().find(|page| page.terminals.contains(&id))
    }

    pub fn current(&self) -> Option<&Workspace> {
        self.containing(self.selected?)
    }

    /// `TabSet.adopt`: into `page`, or a new tab; then selected.
    pub fn adopting(&self, id: PaneId, page: Option<WorkspaceId>) -> Self {
        let mut next = self.clone();
        match page.and_then(|page| next.pages.iter_mut().find(|p| p.id == page)) {
            Some(page) => page.terminals.push(id),
            None => {
                next.next += 1;
                next.pages.push(Workspace {
                    id: WorkspaceId(next.next),
                    terminals: vec![id],
                    focused: id,
                    layout: None,
                });
            }
        }
        next.selecting(id)
    }

    /// `TabSet.select`: a terminal not on screen takes the focused one's place.
    pub fn selecting(&self, id: PaneId) -> Self {
        let mut next = self.clone();
        let Some(page) = next.pages.iter_mut().find(|page| page.terminals.contains(&id)) else {
            return self.clone();
        };
        if let Some(layout) = &page.layout
            && !layout.contains(id)
        {
            page.layout = Some(layout.replacing(page.focused, &Split::Pane(id)));
        }
        page.focused = id;
        next.selected = Some(id);
        next
    }

    /// `TabSet.split`: `new` joins `beside`'s tab, on the named side, selected.
    pub fn splitting(&self, beside: PaneId, new: PaneId, direction: Direction) -> Self {
        let Some(page) = self.containing(beside) else { return self.clone() };
        let base = page.visible();
        let base = if base.contains(beside) {
            base
        } else {
            base.replacing(page.focused, &Split::Pane(beside))
        };
        let layout = base.splitting(beside, new, direction);
        let id = page.id;
        let mut next = self.adopting(new, Some(id));
        if let Some(page) = next.pages.iter_mut().find(|page| page.id == id) {
            page.layout = Some(layout);
        }
        next
    }

    /// `TabSet.close`: the terminal leaves its tab, the split folds, and
    /// the focus moves to the first pane left. A tab left empty goes, and
    /// the selection moves to the last tab's focused terminal.
    pub fn closing(&self, id: PaneId) -> Self {
        let mut next = self.clone();
        let Some(index) = next.pages.iter().position(|page| page.terminals.contains(&id)) else {
            return self.clone();
        };
        let page = &mut next.pages[index];
        page.terminals.retain(|terminal| *terminal != id);
        let remaining = page.layout.as_ref().and_then(|layout| layout.removing(id));
        page.layout = remaining.clone().filter(|layout| layout.ids().len() > 1);
        if page.terminals.is_empty() {
            next.pages.remove(index);
        } else if page.focused == id {
            let focus = remaining
                .and_then(|layout| layout.ids().first().copied())
                .unwrap_or(page.terminals[0]);
            page.focused = focus;
            if next.selected == Some(id) {
                next.selected = Some(focus);
            }
        }
        if next.selected == Some(id) {
            next.selected = next.pages.last().map(|page| page.focused);
        }
        next
    }

    /// `closeWorkspace`: every terminal in the tab. Returns the ones that went.
    pub fn closing_page(&self, page: WorkspaceId) -> (Self, Vec<PaneId>) {
        let terminals = self
            .pages
            .iter()
            .find(|p| p.id == page)
            .map(|p| p.terminals.clone())
            .unwrap_or_default();
        let next = terminals.iter().fold(self.clone(), |state, id| state.closing(*id));
        (next, terminals)
    }

    pub fn with_fraction(&self, page: WorkspaceId, path: &[bool], fraction: f32) -> Self {
        let mut next = self.clone();
        if let Some(page) = next.pages.iter_mut().find(|p| p.id == page) {
            page.layout = page.layout.as_ref().map(|layout| layout.with_fraction(path, fraction));
        }
        next
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: PaneId = PaneId(1);
    const B: PaneId = PaneId(2);
    const C: PaneId = PaneId(3);
    const HIDDEN: PaneId = PaneId(4);
    const NEW: PaneId = PaneId(5);

    fn pair(direction: Direction, first: Split, second: Split) -> Split {
        Split::Branch { direction, first: Box::new(first), second: Box::new(second), fraction: 0.5 }
    }

    fn layout(state: &Workspaces) -> Option<Split> {
        state.current().and_then(|page| page.layout.clone())
    }

    // `WorkspaceSplitTests.leadingSplits`.
    #[test]
    fn left_and_up_remain_in_visual_order_through_nesting_and_close() {
        let state = Workspaces::default()
            .adopting(A, None)
            .splitting(A, B, Direction::Left)
            .splitting(A, C, Direction::Up);
        let expected = pair(
            Direction::Left,
            Split::Pane(B),
            pair(Direction::Up, Split::Pane(C), Split::Pane(A)),
        );
        assert_eq!(layout(&state), Some(expected));
        assert_eq!(state.selected(), Some(C));
        assert_eq!(state.strip(), [A, B, C]);

        let state = state.closing(A);
        assert_eq!(layout(&state), Some(pair(Direction::Left, Split::Pane(B), Split::Pane(C))));
        assert_eq!(state.selected(), Some(C));
        let state = state.closing(C);
        assert_eq!(layout(&state), None);
        assert_eq!(state.selected(), Some(B));
    }

    // `WorkspaceSplitTests.selectionAndJoin`, up to the join.
    #[test]
    fn selection_changes_only_the_focused_pane() {
        let state = Workspaces::default().adopting(A, None);
        let page = state.current().unwrap().id;
        let state = state
            .adopting(HIDDEN, Some(page))
            .selecting(A)
            .splitting(A, B, Direction::Right)
            .selecting(A)
            .selecting(HIDDEN);
        assert_eq!(
            layout(&state),
            Some(pair(Direction::Right, Split::Pane(HIDDEN), Split::Pane(B)))
        );
        let state = state.adopting(NEW, Some(page));
        assert_eq!(layout(&state), Some(pair(Direction::Right, Split::Pane(NEW), Split::Pane(B))));
        assert_eq!(state.strip().len(), 4);
        assert_eq!(state.selected(), Some(NEW));
    }

    #[test]
    fn closing_the_last_terminal_of_a_tab_selects_the_last_tab() {
        let state = Workspaces::default().adopting(A, None).adopting(B, None).adopting(C, None);
        let state = state.selecting(A).closing(A);
        assert_eq!(state.selected(), Some(C));
        assert_eq!(state.pages().len(), 2);
        let state = state.closing(B).closing(C);
        assert_eq!(state.selected(), None);
        assert!(state.pages().is_empty());
    }

    #[test]
    fn closing_a_tab_closes_its_terminals() {
        let state = Workspaces::default()
            .adopting(A, None)
            .splitting(A, B, Direction::Down)
            .adopting(C, None);
        let page = state.containing(A).unwrap().id;
        let (state, gone) = state.closing_page(page);
        assert_eq!(gone, [A, B]);
        assert_eq!(state.strip(), [C]);
        assert_eq!(state.selected(), Some(C));
    }

    #[test]
    fn unknown_terminals_change_nothing() {
        let state = Workspaces::default().adopting(A, None);
        assert_eq!(state.selecting(B), state);
        assert_eq!(state.closing(B), state);
        assert_eq!(state.splitting(B, C, Direction::Right), state);
    }
}
