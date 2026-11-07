//! App-local workspace. No GPUI types, no host library, no sessions.

use std::mem;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TabId(pub(crate) u64);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct PaneId(pub(crate) u64);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Axis {
    Horizontal,
    Vertical,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Host {
    pub name: String,
    pub detail: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tab {
    pub id: TabId,
    pub title: String,
    pub host_name: String,
    pub host_detail: String,
    pub busy: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Pane {
    pub id: PaneId,
    pub tabs: Vec<Tab>,
    pub selected: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Node {
    Pane(Pane),
    Split { axis: Axis, ratio: f32, first: Box<Node>, second: Box<Node> },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CloseOutcome {
    Closed,
    NeedsConfirm,
    CloseWindow,
}

#[derive(Clone, Debug, PartialEq)]
pub struct WorkspaceModel {
    root: Node,
    focused: PaneId,
    next_tab: u64,
    next_pane: u64,
    hosts: Vec<Host>,
    pending: Option<TabId>,
    close_window: bool,
}

impl WorkspaceModel {
    pub fn fixture() -> Self {
        let hosts = vec![
            Host { name: "localhost".into(), detail: "this machine".into() },
            Host { name: "shell".into(), detail: "example".into() },
            Host { name: "build".into(), detail: "example".into() },
        ];
        let mut model = Self {
            root: Node::Pane(Pane { id: PaneId(1), tabs: Vec::new(), selected: 0 }),
            focused: PaneId(1),
            next_tab: 1,
            next_pane: 2,
            hosts,
            pending: None,
            close_window: false,
        };
        let local = model.local_tab();
        model.push_tab(local);
        let mut busy = model.local_tab();
        busy.title = "build".into();
        busy.host_name = "build".into();
        busy.host_detail = "example".into();
        busy.busy = true;
        model.push_tab(busy);
        model
    }

    pub fn hosts(&self) -> &[Host] {
        &self.hosts
    }

    pub fn root(&self) -> &Node {
        &self.root
    }

    pub fn focused_pane(&self) -> PaneId {
        self.focused
    }

    pub fn pending(&self) -> Option<TabId> {
        self.pending
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub fn should_close_window(&self) -> bool {
        self.close_window
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub fn pane_count(&self) -> usize {
        pane_count(&self.root)
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub fn ratios(&self) -> Vec<f32> {
        let mut ratios = Vec::new();
        collect_ratios(&self.root, &mut ratios);
        ratios
    }

    pub fn focused_tab(&self) -> Option<&Tab> {
        self.pane(self.focused).and_then(|pane| pane.tabs.get(pane.selected))
    }

    /// Tabs whose shell is on this machine. A name is the only distinction;
    /// there is no kind field.
    pub fn local_ids(&self) -> Vec<u64> {
        let mut ids = Vec::new();
        collect_local(&self.root, &mut ids);
        ids
    }

    pub fn focused_local(&self) -> Option<u64> {
        self.focused_tab().filter(|tab| is_local(tab)).map(|tab| tab.id.0)
    }

    pub fn focus_first_local(&mut self) {
        if let Some(id) = first_local(&self.root) {
            self.focus_tab(id);
        }
    }

    pub fn tab(&self, id: TabId) -> Option<&Tab> {
        find_tab(&self.root, id)
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub fn select_tab(&mut self, pane: PaneId, index: usize) {
        if let Some(pane) = self.pane_mut(pane)
            && index < pane.tabs.len()
        {
            pane.selected = index;
            self.focused = pane.id;
        }
    }

    pub fn focus_pane(&mut self, pane: PaneId) {
        if self.pane(pane).is_some() {
            self.focused = pane;
        }
    }

    pub fn focus_tab(&mut self, id: TabId) {
        self.select_tab_id(id);
    }

    /// Previous and next tab stay inside the focused pane, wrapping at the ends.
    pub fn cycle_tab(&mut self, forward: bool) {
        let pane_id = self.focused;
        let Some(pane) = self.pane(pane_id) else {
            return;
        };
        let count = pane.tabs.len();
        if count == 0 {
            return;
        }
        let next =
            if forward { (pane.selected + 1) % count } else { (pane.selected + count - 1) % count };
        self.select_tab(pane_id, next);
    }

    pub fn new_tab(&mut self) {
        let tab = self.local_tab();
        self.push_tab(tab);
    }

    pub fn assign_host_to_focused(&mut self, name: &str) {
        let Some(host) = self.hosts.iter().find(|host| host.name == name).cloned() else {
            return;
        };
        let focused = self.focused;
        let Some(pane) = self.pane_mut(focused) else {
            return;
        };
        let Some(tab) = pane.tabs.get_mut(pane.selected) else {
            return;
        };
        tab.title = host.name.clone();
        tab.host_name = host.name;
        tab.host_detail = host.detail;
    }

    pub fn split(&mut self, axis: Axis) {
        let focused = self.focused;
        let mut new_pane = Some(self.fresh_pane());
        let Some(root) = take_root(&mut self.root) else {
            return;
        };
        let (root, _) = replace_pane(root, focused, &mut |pane| Node::Split {
            axis,
            ratio: 0.5,
            first: Box::new(Node::Pane(pane)),
            second: Box::new(Node::Pane(new_pane.take().expect("a pane splits once"))),
        });
        self.root = root;
    }

    /// Close control and middle-click share this path.
    pub fn request_close(&mut self, id: TabId) -> CloseOutcome {
        if self.pending.is_some() {
            return CloseOutcome::NeedsConfirm;
        }
        let Some(tab) = self.tab(id) else {
            return CloseOutcome::Closed;
        };
        if tab.busy {
            self.pending = Some(id);
            return CloseOutcome::NeedsConfirm;
        }
        self.remove_tab(id)
    }

    pub fn confirm_close(&mut self) -> CloseOutcome {
        let Some(id) = self.pending.take() else {
            return CloseOutcome::Closed;
        };
        self.remove_tab(id)
    }

    pub fn cancel_close(&mut self) {
        self.pending = None;
    }

    pub fn request_close_focused(&mut self) -> CloseOutcome {
        let Some(id) = self.focused_tab().map(|tab| tab.id) else {
            return CloseOutcome::Closed;
        };
        self.request_close(id)
    }

    fn local_tab(&mut self) -> Tab {
        let id = TabId(self.next_tab);
        self.next_tab += 1;
        Tab {
            id,
            title: "localhost".into(),
            host_name: "localhost".into(),
            host_detail: "this machine".into(),
            busy: false,
        }
    }

    fn fresh_pane(&mut self) -> Pane {
        let id = PaneId(self.next_pane);
        self.next_pane += 1;
        let tab = self.local_tab();
        Pane { id, tabs: vec![tab], selected: 0 }
    }

    fn push_tab(&mut self, tab: Tab) {
        let focused = self.focused;
        if let Some(pane) = self.pane_mut(focused) {
            pane.tabs.push(tab);
            pane.selected = pane.tabs.len() - 1;
        }
    }

    fn remove_tab(&mut self, id: TabId) -> CloseOutcome {
        if tab_count(&self.root) <= 1 && find_tab(&self.root, id).is_some() {
            self.root = Node::Pane(Pane { id: self.focused, tabs: Vec::new(), selected: 0 });
            self.close_window = true;
            return CloseOutcome::CloseWindow;
        }
        let selected_before = self.focused_tab().map(|tab| tab.id);
        let Some(root) = take_root(&mut self.root) else {
            return CloseOutcome::Closed;
        };
        let mut emptied = None;
        let root = detach_tab(root, id, &mut emptied);
        self.root = match emptied {
            Some(empty) => collapse(root, empty),
            None => root,
        };
        if self.pane(self.focused).is_none()
            && let Some(first) = first_pane(&self.root)
        {
            self.focused = first;
        }
        if let Some(keep) = selected_before
            && keep != id
        {
            self.select_tab_id(keep);
        }
        CloseOutcome::Closed
    }

    fn select_tab_id(&mut self, id: TabId) {
        let Some(root) = take_root(&mut self.root) else {
            return;
        };
        let mut found = None;
        let root = map_panes(root, &mut |mut pane| {
            if let Some(index) = pane.tabs.iter().position(|tab| tab.id == id) {
                pane.selected = index;
                found = Some(pane.id);
            }
            pane
        });
        self.root = root;
        if let Some(pane) = found {
            self.focused = pane;
        }
    }

    fn pane(&self, id: PaneId) -> Option<&Pane> {
        find_pane(&self.root, id)
    }

    fn pane_mut(&mut self, id: PaneId) -> Option<&mut Pane> {
        find_pane_mut(&mut self.root, id)
    }
}

fn take_root(root: &mut Node) -> Option<Node> {
    let empty = Node::Pane(Pane { id: PaneId(0), tabs: Vec::new(), selected: 0 });
    Some(mem::replace(root, empty))
}

#[cfg_attr(not(test), allow(dead_code))]
fn pane_count(node: &Node) -> usize {
    match node {
        Node::Pane(_) => 1,
        Node::Split { first, second, .. } => pane_count(first) + pane_count(second),
    }
}

fn tab_count(node: &Node) -> usize {
    match node {
        Node::Pane(pane) => pane.tabs.len(),
        Node::Split { first, second, .. } => tab_count(first) + tab_count(second),
    }
}

#[cfg_attr(not(test), allow(dead_code))]
fn collect_ratios(node: &Node, ratios: &mut Vec<f32>) {
    if let Node::Split { ratio, first, second, .. } = node {
        ratios.push(*ratio);
        collect_ratios(first, ratios);
        collect_ratios(second, ratios);
    }
}

fn find_pane(node: &Node, id: PaneId) -> Option<&Pane> {
    match node {
        Node::Pane(pane) if pane.id == id => Some(pane),
        Node::Pane(_) => None,
        Node::Split { first, second, .. } => find_pane(first, id).or_else(|| find_pane(second, id)),
    }
}

fn find_pane_mut(node: &mut Node, id: PaneId) -> Option<&mut Pane> {
    match node {
        Node::Pane(pane) if pane.id == id => Some(pane),
        Node::Pane(_) => None,
        Node::Split { first, second, .. } => {
            find_pane_mut(first, id).or_else(|| find_pane_mut(second, id))
        }
    }
}

fn find_tab(node: &Node, id: TabId) -> Option<&Tab> {
    match node {
        Node::Pane(pane) => pane.tabs.iter().find(|tab| tab.id == id),
        Node::Split { first, second, .. } => find_tab(first, id).or_else(|| find_tab(second, id)),
    }
}

fn is_local(tab: &Tab) -> bool {
    tab.host_name == "localhost"
}

fn collect_local(node: &Node, ids: &mut Vec<u64>) {
    match node {
        Node::Pane(pane) => {
            ids.extend(pane.tabs.iter().filter(|tab| is_local(tab)).map(|tab| tab.id.0));
        }
        Node::Split { first, second, .. } => {
            collect_local(first, ids);
            collect_local(second, ids);
        }
    }
}

fn first_local(node: &Node) -> Option<TabId> {
    match node {
        Node::Pane(pane) => pane.tabs.iter().find(|tab| is_local(tab)).map(|tab| tab.id),
        Node::Split { first, second, .. } => first_local(first).or_else(|| first_local(second)),
    }
}

fn first_pane(node: &Node) -> Option<PaneId> {
    match node {
        Node::Pane(pane) => Some(pane.id),
        Node::Split { first, .. } => first_pane(first),
    }
}

fn replace_pane(node: Node, id: PaneId, replace: &mut dyn FnMut(Pane) -> Node) -> (Node, bool) {
    match node {
        Node::Pane(pane) if pane.id == id => (replace(pane), true),
        Node::Pane(pane) => (Node::Pane(pane), false),
        Node::Split { axis, ratio, first, second } => {
            let (first, hit) = replace_pane(*first, id, replace);
            if hit {
                return (Node::Split { axis, ratio, first: Box::new(first), second }, true);
            }
            let (second, hit) = replace_pane(*second, id, replace);
            (Node::Split { axis, ratio, first: Box::new(first), second: Box::new(second) }, hit)
        }
    }
}

fn map_panes(node: Node, map: &mut dyn FnMut(Pane) -> Pane) -> Node {
    match node {
        Node::Pane(pane) => Node::Pane(map(pane)),
        Node::Split { axis, ratio, first, second } => Node::Split {
            axis,
            ratio,
            first: Box::new(map_panes(*first, map)),
            second: Box::new(map_panes(*second, map)),
        },
    }
}

fn detach_tab(node: Node, id: TabId, emptied: &mut Option<PaneId>) -> Node {
    match node {
        Node::Pane(mut pane) => {
            let selected_id = pane.tabs.get(pane.selected).map(|tab| tab.id);
            let before = pane.tabs.len();
            pane.tabs.retain(|tab| tab.id != id);
            if pane.tabs.len() != before {
                if pane.tabs.is_empty() {
                    *emptied = Some(pane.id);
                    pane.selected = 0;
                } else if selected_id != Some(id) {
                    if let Some(index) = selected_id
                        .and_then(|selected| pane.tabs.iter().position(|tab| tab.id == selected))
                    {
                        pane.selected = index;
                    }
                } else {
                    pane.selected = pane.selected.min(pane.tabs.len() - 1);
                }
            }
            Node::Pane(pane)
        }
        Node::Split { axis, ratio, first, second } => Node::Split {
            axis,
            ratio,
            first: Box::new(detach_tab(*first, id, emptied)),
            second: Box::new(detach_tab(*second, id, emptied)),
        },
    }
}

fn collapse(node: Node, empty: PaneId) -> Node {
    match node {
        Node::Split { axis, ratio, first, second } => {
            if let Node::Pane(pane) = first.as_ref()
                && pane.id == empty
            {
                return *second;
            }
            if let Node::Pane(pane) = second.as_ref()
                && pane.id == empty
            {
                return *first;
            }
            Node::Split {
                axis,
                ratio,
                first: Box::new(collapse(*first, empty)),
                second: Box::new(collapse(*second, empty)),
            }
        }
        other => other,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ThemeChoice {
    System,
    Dark,
    Light,
}

impl ThemeChoice {
    pub fn is_dark(self, system_dark: bool) -> bool {
        match self {
            ThemeChoice::System => system_dark,
            ThemeChoice::Dark => true,
            ThemeChoice::Light => false,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Command {
    NewTab,
    CloseTab,
    PreviousTab,
    NextTab,
    SplitRight,
    SplitDown,
    Settings,
    ThemeSystem,
    ThemeDark,
    ThemeLight,
}

pub fn command_name(command: Command) -> &'static str {
    match command {
        Command::NewTab => "New Tab",
        Command::CloseTab => "Close Tab",
        Command::PreviousTab => "Previous Tab",
        Command::NextTab => "Next Tab",
        Command::SplitRight => "Split Right",
        Command::SplitDown => "Split Down",
        Command::Settings => "Settings",
        Command::ThemeSystem => "System",
        Command::ThemeDark => "Dark",
        Command::ThemeLight => "Light",
    }
}

const COMMANDS: [Command; 10] = [
    Command::NewTab,
    Command::CloseTab,
    Command::PreviousTab,
    Command::NextTab,
    Command::SplitRight,
    Command::SplitDown,
    Command::Settings,
    Command::ThemeSystem,
    Command::ThemeDark,
    Command::ThemeLight,
];

pub fn matching_commands(query: &str) -> Vec<Command> {
    let query = query.trim().to_lowercase();
    COMMANDS
        .into_iter()
        .filter(|command| {
            query.is_empty() || command_name(*command).to_lowercase().contains(&query)
        })
        .collect()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InputTarget {
    Workspace,
    Palette,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CommandEffect {
    Ignored,
    None,
    Quit,
    OpenSettings,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Session {
    pub model: WorkspaceModel,
    pub theme: ThemeChoice,
    pub palette_open: bool,
    pub palette_query: String,
    pub palette_index: usize,
    pub host_picker_open: bool,
    pub input: InputTarget,
}

impl Session {
    pub fn fixture() -> Self {
        Self {
            model: WorkspaceModel::fixture(),
            theme: ThemeChoice::System,
            palette_open: false,
            palette_query: String::new(),
            palette_index: 0,
            host_picker_open: false,
            input: InputTarget::Workspace,
        }
    }

    pub fn accept_workspace_shortcut(&self) -> bool {
        !self.palette_open && self.model.pending().is_none() && self.input != InputTarget::Palette
    }

    pub fn open_palette(&mut self) {
        self.palette_open = true;
        self.palette_query.clear();
        self.palette_index = 0;
        self.host_picker_open = false;
        self.input = InputTarget::Palette;
    }

    pub fn close_palette(&mut self) {
        self.palette_open = false;
        self.palette_query.clear();
        self.palette_index = 0;
        self.input = InputTarget::Workspace;
    }

    pub fn palette_push(&mut self, ch: char) {
        self.palette_query.push(ch);
        self.clamp_palette_index();
    }

    pub fn palette_backspace(&mut self) {
        self.palette_query.pop();
        self.clamp_palette_index();
    }

    pub fn move_palette(&mut self, delta: isize) {
        let len = matching_commands(&self.palette_query).len();
        if len == 0 {
            self.palette_index = 0;
            return;
        }
        let next = self.palette_index as isize + delta;
        self.palette_index = next.clamp(0, len as isize - 1) as usize;
    }

    pub fn workspace_shortcut(&mut self, command: Command) -> CommandEffect {
        if !self.accept_workspace_shortcut() {
            return CommandEffect::Ignored;
        }
        self.run_command(command)
    }

    pub fn run_command(&mut self, command: Command) -> CommandEffect {
        self.close_palette();
        match command {
            Command::NewTab => {
                self.model.new_tab();
                CommandEffect::None
            }
            Command::CloseTab => {
                let outcome = self.model.request_close_focused();
                self.effect_of(outcome)
            }
            Command::PreviousTab => {
                self.model.cycle_tab(false);
                CommandEffect::None
            }
            Command::NextTab => {
                self.model.cycle_tab(true);
                CommandEffect::None
            }
            Command::SplitRight => {
                self.model.split(Axis::Horizontal);
                CommandEffect::None
            }
            Command::SplitDown => {
                self.model.split(Axis::Vertical);
                CommandEffect::None
            }
            Command::Settings => CommandEffect::OpenSettings,
            Command::ThemeSystem => {
                self.theme = ThemeChoice::System;
                CommandEffect::None
            }
            Command::ThemeDark => {
                self.theme = ThemeChoice::Dark;
                CommandEffect::None
            }
            Command::ThemeLight => {
                self.theme = ThemeChoice::Light;
                CommandEffect::None
            }
        }
    }

    pub fn request_close(&mut self, id: TabId) -> CommandEffect {
        let outcome = self.model.request_close(id);
        self.effect_of(outcome)
    }

    pub fn confirm_close(&mut self) -> CommandEffect {
        let outcome = self.model.confirm_close();
        self.effect_of(outcome)
    }

    pub fn cancel_close(&mut self) {
        self.model.cancel_close();
    }

    fn effect_of(&mut self, outcome: CloseOutcome) -> CommandEffect {
        match outcome {
            CloseOutcome::CloseWindow => CommandEffect::Quit,
            CloseOutcome::Closed | CloseOutcome::NeedsConfirm => CommandEffect::None,
        }
    }

    fn clamp_palette_index(&mut self) {
        let len = matching_commands(&self.palette_query).len();
        if len == 0 {
            self.palette_index = 0;
        } else if self.palette_index >= len {
            self.palette_index = len - 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn titles(model: &WorkspaceModel) -> Vec<&str> {
        let Node::Pane(pane) = model.root() else {
            panic!("expected one pane");
        };
        pane.tabs.iter().map(|tab| tab.title.as_str()).collect()
    }

    #[test]
    fn closing_a_background_tab_keeps_the_selection() {
        let mut model = WorkspaceModel::fixture();
        let pane = model.focused_pane();
        let background = model.pane(pane).unwrap().tabs[1].id;
        model.select_tab(pane, 0);
        let selected = model.focused_tab().unwrap().id;
        assert_ne!(selected, background);
        assert_eq!(model.request_close(background), CloseOutcome::NeedsConfirm);
        model.confirm_close();
        assert_eq!(model.focused_tab().unwrap().id, selected);
        assert!(model.tab(background).is_none());
    }

    #[test]
    fn closing_the_selected_tab_selects_the_neighbor() {
        let mut model = WorkspaceModel::fixture();
        model.new_tab();
        let pane = model.focused_pane();
        let ids: Vec<_> = model.pane(pane).unwrap().tabs.iter().map(|tab| tab.id).collect();
        model.select_tab(pane, 0);
        assert_eq!(model.request_close(ids[0]), CloseOutcome::Closed);
        assert_eq!(model.focused_tab().unwrap().id, ids[1]);
    }

    #[test]
    fn a_busy_tab_closes_only_after_confirm() {
        let mut model = WorkspaceModel::fixture();
        let busy = model.pane(model.focused_pane()).unwrap().tabs[1].id;
        assert_eq!(model.request_close(busy), CloseOutcome::NeedsConfirm);
        assert!(model.tab(busy).is_some());
        model.cancel_close();
        assert!(model.tab(busy).is_some());
        assert!(model.pending().is_none());
        model.request_close(busy);
        assert_eq!(model.confirm_close(), CloseOutcome::Closed);
        assert!(model.tab(busy).is_none());
    }

    #[test]
    fn the_last_tab_asks_the_window_to_close() {
        let mut model = WorkspaceModel::fixture();
        let pane = model.focused_pane();
        let busy = model.pane(pane).unwrap().tabs[1].id;
        let open = model.pane(pane).unwrap().tabs[0].id;
        model.request_close(busy);
        model.confirm_close();
        assert_eq!(model.request_close(open), CloseOutcome::CloseWindow);
        assert!(model.should_close_window());
        assert!(model.focused_tab().is_none());
    }

    #[test]
    fn the_window_can_open_on_the_local_shell() {
        let mut model = WorkspaceModel::fixture();
        assert_eq!(model.focused_tab().unwrap().host_name, "build");
        assert!(model.focused_local().is_none());
        model.focus_first_local();
        let local = model.focused_local().unwrap();
        assert_eq!(model.focused_tab().unwrap().host_name, "localhost");
        assert_eq!(model.local_ids(), vec![local]);
        model.new_tab();
        assert_eq!(model.local_ids().len(), 2);
        assert_eq!(model.focused_local(), Some(model.focused_tab().unwrap().id.0));
    }

    #[test]
    fn previous_and_next_tab_wrap_inside_the_focused_pane() {
        let mut model = WorkspaceModel::fixture();
        assert_eq!(model.focused_tab().unwrap().title, "build");
        model.cycle_tab(false);
        assert_eq!(model.focused_tab().unwrap().title, "localhost");
        model.cycle_tab(true);
        assert_eq!(model.focused_tab().unwrap().title, "build");
        model.cycle_tab(true);
        assert_eq!(model.focused_tab().unwrap().title, "localhost");
    }

    #[test]
    fn new_tab_is_a_local_profile_and_becomes_selected() {
        let mut model = WorkspaceModel::fixture();
        model.new_tab();
        let tab = model.focused_tab().unwrap();
        assert_eq!(tab.host_name, "localhost");
        assert_eq!(tab.title, "localhost");
        assert!(!tab.busy);
        assert_eq!(titles(&model).len(), 3);
    }

    #[test]
    fn four_panes_keep_nested_ratios_and_clicked_focus() {
        let mut model = WorkspaceModel::fixture();
        model.split(Axis::Horizontal);
        let right = match model.root() {
            Node::Split { second, .. } => match second.as_ref() {
                Node::Pane(pane) => pane.id,
                _ => panic!("second child"),
            },
            _ => panic!("split"),
        };
        model.focus_pane(right);
        model.split(Axis::Vertical);
        let left = match model.root() {
            Node::Split { first, .. } => match first.as_ref() {
                Node::Pane(pane) => pane.id,
                _ => panic!("first"),
            },
            _ => panic!("split"),
        };
        model.focus_pane(left);
        model.split(Axis::Vertical);
        assert_eq!(model.pane_count(), 4);
        assert_eq!(model.ratios(), vec![0.5, 0.5, 0.5]);
        model.focus_pane(right);
        assert_eq!(model.focused_pane(), right);
    }

    #[test]
    fn choosing_a_host_renames_the_focused_tab_and_does_not_dial() {
        let mut model = WorkspaceModel::fixture();
        model.assign_host_to_focused("shell");
        let tab = model.focused_tab().unwrap();
        assert_eq!(tab.title, "shell");
        assert_eq!(tab.host_detail, "example");
        assert_eq!(model.pane_count(), 1);
    }

    #[test]
    fn palette_keys_do_not_run_a_workspace_shortcut() {
        let mut session = Session::fixture();
        let before = tab_count(session.model.root());
        session.open_palette();
        session.palette_push('n');
        assert_eq!(session.workspace_shortcut(Command::NewTab), CommandEffect::Ignored);
        assert_eq!(tab_count(session.model.root()), before);
        assert_eq!(
            matching_commands(&session.palette_query),
            vec![Command::NewTab, Command::NextTab, Command::SplitDown, Command::Settings]
        );
    }

    #[test]
    fn commands_filter_and_theme_stays_in_memory() {
        assert!(matching_commands("split").contains(&Command::SplitRight));
        assert!(matching_commands("nope").is_empty());
        let mut session = Session::fixture();
        assert_eq!(session.run_command(Command::ThemeDark), CommandEffect::None);
        assert_eq!(session.theme, ThemeChoice::Dark);
        assert!(!session.palette_open);
        assert_eq!(session.run_command(Command::Settings), CommandEffect::OpenSettings);
    }
}
