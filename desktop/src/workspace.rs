//! The window and the workspace in it, as the Mac `TabSet` keeps it: one
//! chip per terminal, tabs that lay terminals out, and the chrome.
//!
//! The chrome reports clicks as [`ChromeEvent`]s; this view applies them to
//! [`Workspaces`] and hands the chrome the chips. Each terminal's child
//! surface is laid over its share of the terminal rect. Drawing is
//! `canvas.rs`.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use gpui::{
    App, Bounds, Context, Entity, FocusHandle, KeyDownEvent, Subscription, TitlebarOptions, Window,
    WindowBackgroundAppearance, WindowBounds, WindowOptions, point, prelude::*, px, size,
};
use gpui_platform::application;
use tether_desktop::keys::{self, Stroke};
use tether_desktop::labels::{self, Label};
use tether_desktop::split::{Direction, PaneId, Path};
use tether_desktop::workspaces::{WorkspaceId, Workspaces};
use tether_ffi::{LocalShell, Session, TerminalInput, open_local};
use tether_ui::{Assets, Chrome, ChromeEvent, ChromeView, Ink, Workspace};
use tokio::runtime::Runtime;

use crate::pane::Pane;
use crate::platform::{self, TerminalLayer};

const TITLE: &str = "Tether";
const SCROLLBACK: u32 = 10_000;
const LOCALHOST: &str = "localhost";

pub fn run() -> Result<(), String> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("tether-session")
        .build()
        .map_err(|error| error.to_string())?;
    let runtime = Arc::new(runtime);
    application().with_assets(Assets).run(move |cx: &mut App| {
        let opened = cx.open_window(options(cx), |window, cx| {
            let chrome = cx.new(|_| ChromeView {
                workspace: Workspace::mac(Chrome::WINDOW_WIDTH, Chrome::WINDOW_HEIGHT),
                tabs: Vec::new(),
                host: LOCALHOST.to_owned(),
                hosts: vec![LOCALHOST.to_owned()],
                host_open: false,
                settings_open: false,
                ink: dark_ink(),
                symbols: platform::symbols(),
                ended: false,
            });
            cx.new(|cx| Desktop::new(chrome, runtime.clone(), window, cx))
        });
        if let Err(error) = opened {
            eprintln!("tether-desktop: window: {error}");
            cx.quit();
            return;
        }
        platform::place_window(TITLE);
        cx.spawn(async move |cx| {
            // AppKit applies a saved frame at the end of finish-launching.
            for delay in [50, 300] {
                cx.background_executor().timer(std::time::Duration::from_millis(delay)).await;
                cx.update(|_| platform::place_window(TITLE));
            }
        })
        .detach();
        cx.on_window_closed(|cx, _| cx.quit()).detach();
    });
    Ok(())
}

fn options(cx: &App) -> WindowOptions {
    let wanted = size(px(Chrome::WINDOW_WIDTH), px(Chrome::WINDOW_HEIGHT));
    let bounds = cx
        .primary_display()
        .map(|display| Bounds::centered_at(display.visible_bounds().center(), wanted))
        .unwrap_or_else(|| Bounds::new(point(px(80.0), px(80.0)), wanted));
    WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: Some(TitlebarOptions {
            title: Some(TITLE.into()),
            appears_transparent: true,
            // AppKit's own cluster; the layout reserves `Chrome::TRAFFIC_LIGHTS` for it.
            traffic_light_position: None,
        }),
        app_id: Some("tether-desktop".to_owned()),
        window_background: WindowBackgroundAppearance::Opaque,
        // The strip is ours. Without this macOS delays clicks there while it decides about a drag.
        app_owns_titlebar_drag: true,
        window_min_size: Some(size(px(Chrome::WINDOW_MIN_WIDTH), px(Chrome::WINDOW_MIN_HEIGHT))),
        focus: true,
        show: true,
        ..Default::default()
    }
}

/// A divider being dragged: whose tab, which branch.
pub(crate) struct Drag {
    pub page: WorkspaceId,
    pub path: Path,
}

pub(crate) struct Desktop {
    pub(crate) chrome: Entity<ChromeView>,
    pub(crate) workspaces: Workspaces,
    pub(crate) panes: HashMap<PaneId, Pane>,
    /// Chip titles, worked out together so twins are numbered.
    pub(crate) titles: HashMap<PaneId, String>,
    /// Terminals whose shell has ended. They stay, as on a Mac, with the last screen.
    pub(crate) ended: HashSet<PaneId>,
    /// A close is being checked or asked; another waits for it.
    pub(crate) closing: bool,
    /// `Terminal N`, numbered per host as terminals open.
    serials: HashMap<PaneId, String>,
    pub(crate) drag: Option<Drag>,
    /// The terminal a press began on, which hears the drag and the release.
    pub(crate) pointer_pane: Option<PaneId>,
    /// What the input method is composing, drawn at the cursor and not sent.
    pub(crate) marked: String,
    pub(crate) focus: FocusHandle,
    pub(crate) runtime: Arc<Runtime>,
    next_pane: u64,
    _chrome_events: Subscription,
}

impl Desktop {
    fn new(
        chrome: Entity<ChromeView>,
        runtime: Arc<Runtime>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let events = cx.subscribe_in(&chrome, window, |this, _, event, window, cx| {
            this.chrome_event(*event, window, cx);
        });
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        let mut desktop = Self {
            chrome,
            workspaces: Workspaces::default(),
            panes: HashMap::new(),
            titles: HashMap::new(),
            ended: HashSet::new(),
            closing: false,
            serials: HashMap::new(),
            drag: None,
            pointer_pane: None,
            marked: String::new(),
            focus,
            runtime,
            next_pane: 0,
            _chrome_events: events,
        };
        // The app opens a local terminal at launch.
        desktop.open(None, window, cx);
        desktop
    }

    fn chrome_event(&mut self, event: ChromeEvent, window: &mut Window, cx: &mut Context<Self>) {
        let strip = self.workspaces.strip();
        match event {
            // A second click on the selected chip opens its menu (`handleTabClick`).
            ChromeEvent::Select(index) => match strip.get(index) {
                Some(id) if self.workspaces.selected() == Some(*id) => {
                    self.open_tab_menu(*id, window, cx)
                }
                Some(id) => self.workspaces = self.workspaces.selecting(*id),
                None => {}
            },
            ChromeEvent::Menu(index) => {
                if let Some(id) = strip.get(index) {
                    self.open_tab_menu(*id, window, cx);
                }
            }
            ChromeEvent::Close(index) => {
                if let Some(id) = strip.get(index) {
                    self.request_close(*id, window, cx);
                }
            }
            ChromeEvent::NewTab => self.open(None, window, cx),
            // One host and no settings window yet: P3 and P4.
            ChromeEvent::PickHost(_) | ChromeEvent::Settings => {}
        }
        window.focus(&self.focus, cx);
        self.sync(cx);
    }

    /// A terminal on this machine: a new tab (`⌘T`), or into `page` (`⌘N`).
    pub(crate) fn open(
        &mut self,
        page: Option<WorkspaceId>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let id = self.new_terminal_id();
        self.workspaces = self.workspaces.adopting(id, page);
        self.start_shell(id, window, cx);
    }

    /// `⌘\` and `⇧⌘\`: a new terminal beside the selected one.
    pub(crate) fn split(
        &mut self,
        direction: Direction,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(beside) = self.workspaces.selected() else { return };
        let id = self.new_terminal_id();
        self.workspaces = self.workspaces.splitting(beside, id, direction);
        self.start_shell(id, window, cx);
    }

    fn new_terminal_id(&mut self) -> PaneId {
        self.next_pane += 1;
        let id = PaneId(self.next_pane);
        self.serials.insert(id, format!("Terminal {}", self.next_pane));
        id
    }

    fn start_shell(&mut self, id: PaneId, window: &mut Window, cx: &mut Context<Self>) {
        let layer = match TerminalLayer::attach(window) {
            Ok(layer) => layer,
            Err(error) => {
                eprintln!("tether-desktop: {error}");
                self.sync(cx);
                return;
            }
        };
        let (sender, receiver) = tokio::sync::oneshot::channel();
        self.runtime.spawn(async move {
            let _ = sender.send(open_local(local_shell()).await);
        });
        cx.spawn_in(window, async move |this, cx| {
            let opened = receiver.await;
            let _ = this.update(cx, |this, cx| match opened {
                Ok(Ok(session)) => this.attach(id, session, layer, cx),
                Ok(Err(error)) => {
                    eprintln!("tether-desktop: local shell: {error}");
                    this.close_terminal(id);
                    this.sync(cx);
                }
                Err(_) => {
                    this.close_terminal(id);
                    this.sync(cx);
                }
            });
        })
        .detach();
        self.sync(cx);
    }

    fn attach(
        &mut self,
        id: PaneId,
        session: Arc<Session>,
        layer: TerminalLayer,
        cx: &mut Context<Self>,
    ) {
        if self.workspaces.containing(id).is_none() {
            session.close();
            return;
        }
        let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
        let watched = session.clone();
        self.runtime.spawn(async move {
            while watched.await_change().await {
                if sender.send(()).is_err() {
                    break;
                }
            }
        });
        cx.spawn(async move |this, cx| {
            while receiver.recv().await.is_some() {
                // Draw once for however many changes arrived since the last frame.
                while receiver.try_recv().is_ok() {}
                if this.update(cx, |this, cx| this.redraw(id, cx)).is_err() {
                    return;
                }
            }
            let _ = this.update(cx, |this, cx| {
                this.ended.insert(id);
                this.sync(cx);
            });
        })
        .detach();
        let mut pane = Pane::new(session, layer, self.ink(cx).accent);
        pane.refresh_labels();
        self.panes.insert(id, pane);
        self.sync(cx);
    }

    fn redraw(&mut self, id: PaneId, cx: &mut Context<Self>) {
        let Some(pane) = self.panes.get_mut(&id) else { return };
        let renamed = pane.refresh_labels();
        pane.draw();
        if renamed {
            self.sync(cx);
        }
    }

    pub(crate) fn select(&mut self, id: PaneId, cx: &mut Context<Self>) {
        self.workspaces = self.workspaces.selecting(id);
        self.sync(cx);
    }

    pub(crate) fn resize_split(&mut self, fraction: f32, cx: &mut Context<Self>) {
        let Some(drag) = &self.drag else { return };
        self.workspaces = self.workspaces.with_fraction(drag.page, &drag.path, fraction);
        cx.notify();
    }

    /// One terminal goes, and its split folds. Asked first: `request_close`.
    pub(crate) fn close_terminal(&mut self, id: PaneId) {
        self.workspaces = self.workspaces.closing(id);
        self.forget(id);
    }

    /// A tab and every terminal in it. Asked first: `request_close_tab`.
    pub(crate) fn close_page(&mut self, page: WorkspaceId) {
        let (workspaces, gone) = self.workspaces.closing_page(page);
        self.workspaces = workspaces;
        for id in gone {
            self.forget(id);
        }
    }

    fn forget(&mut self, id: PaneId) {
        if let Some(mut pane) = self.panes.remove(&id) {
            pane.close();
        }
        self.ended.remove(&id);
        self.serials.remove(&id);
        self.titles.remove(&id);
    }

    /// The one place the chips are worked out (`TerminalLabels`) and handed
    /// to the chrome, which is a separate view and draws from its own copy.
    pub(crate) fn sync(&mut self, cx: &mut Context<Self>) {
        let home = std::env::var("HOME").ok();
        let strip = self.workspaces.strip();
        let rows: Vec<Label> = strip
            .iter()
            .map(|id| {
                let pane = self.panes.get(id);
                Label {
                    id: Some(*id),
                    command: pane.and_then(|pane| pane.command.clone()),
                    directory: labels::directory_name(
                        pane.and_then(|pane| pane.directory.as_deref()),
                        home.as_deref(),
                    ),
                    serial: self.serials.get(id).cloned().unwrap_or_default(),
                    ..Label::default()
                }
            })
            .collect();
        self.titles = labels::titles(&rows);
        let selected = self.workspaces.selected();
        let chips: Vec<tether_ui::Tab> = strip
            .iter()
            .map(|id| tether_ui::Tab {
                title: self.titles.get(id).cloned().unwrap_or_default(),
                selected: selected == Some(*id),
            })
            .collect();
        let ended = selected.is_some_and(|id| self.ended.contains(&id));
        self.chrome.update(cx, |view, cx| {
            if view.tabs != chips || view.ended != ended {
                view.tabs = chips;
                view.ended = ended;
                cx.notify();
            }
        });
        cx.notify();
    }

    pub(crate) fn key_down(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let keystroke = &event.keystroke;
        let modifiers = keystroke.modifiers;
        if modifiers.platform {
            // Menus and key bindings are P4. These are `WorkspaceAction`'s defaults.
            match (keystroke.key.as_str(), modifiers.shift, modifiers.alt) {
                ("t", false, false) => self.open(None, window, cx),
                ("n", false, false) => {
                    let page = self.workspaces.current().map(|page| page.id);
                    self.open(page, window, cx);
                }
                ("w", false, false) => {
                    if let Some(id) = self.workspaces.selected() {
                        self.request_close(id, window, cx);
                    }
                }
                ("w", false, true) => {
                    if let Some(page) = self.workspaces.current().map(|page| page.id) {
                        self.request_close_tab(page, window, cx);
                    }
                }
                // `previousTerminal` / `nextTerminal`, and the tabs (`cycleTab`).
                ("up", false, true) => self.workspaces = self.workspaces.cycling_terminal(false),
                ("down", false, true) => self.workspaces = self.workspaces.cycling_terminal(true),
                ("left", false, true) | ("[" | "{", true, false) => {
                    self.workspaces = self.workspaces.cycling_tab(false)
                }
                ("right", false, true) | ("]" | "}", true, false) => {
                    self.workspaces = self.workspaces.cycling_tab(true)
                }
                ("\\", false, false) => self.split(Direction::Right, window, cx),
                ("\\", true, false) | ("|", _, false) => self.split(Direction::Down, window, cx),
                ("v", false, false) => {
                    if let Some(text) = cx.read_from_clipboard().and_then(|item| item.text()) {
                        self.send(TerminalInput::Paste { text });
                    }
                }
                ("c", false, false) => {
                    let selected = self.workspaces.selected().and_then(|id| self.panes.get(&id));
                    if let Some(text) = selected.and_then(Pane::copy) {
                        cx.write_to_clipboard(gpui::ClipboardItem::new_string(text));
                    }
                }
                ("q", false, false) => cx.quit(),
                _ => return,
            }
            cx.stop_propagation();
            self.sync(cx);
            return;
        }
        let stroke = Stroke {
            key: &keystroke.key,
            key_char: keystroke.key_char.as_deref(),
            shift: modifiers.shift,
            alt: modifiers.alt,
            control: modifiers.control,
            platform: modifiers.platform,
        };
        if let Some(input) = keys::input(stroke) {
            self.send(input);
            cx.stop_propagation();
        }
    }

    /// Text an input method committed.
    pub(crate) fn type_text(&self, text: &str) {
        self.send(crate::ime::typed(text));
    }

    fn send(&self, input: TerminalInput) {
        let Some(id) = self.workspaces.selected() else { return };
        if self.ended.contains(&id) {
            return;
        }
        let Some(pane) = self.panes.get(&id) else { return };
        if let Err(error) = pane.session.send(input) {
            eprintln!("tether-desktop: input: {error}");
        }
    }

    pub(crate) fn ink(&self, cx: &App) -> Ink {
        self.chrome.read(cx).ink
    }
}

fn local_shell() -> LocalShell {
    LocalShell {
        directory: None,
        // What the Mac app asks for (`SessionModel`).
        term: "xterm-256color".to_owned(),
        columns: 80,
        rows: 24,
        scrollback_lines: SCROLLBACK,
        shell: None,
        history: None,
    }
}

/// The Mac's dark semantic colours, as the preview sampled them. Appearance
/// following the system is a platform service for later.
fn dark_ink() -> Ink {
    Ink {
        text: 0xFFFFFF,
        subtle: 0xFFFFFF,
        separator: 0xFFFFFF,
        accent: 0x007AFF,
        surface: 0x1E1E1E,
        presence: 0x30D158,
        text_alpha: 0.85,
        subtle_alpha: 0.55,
        separator_alpha: 0.10,
    }
}
