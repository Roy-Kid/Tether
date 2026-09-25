//! Transport-independent tmux workspaces. Protocol parsing is composed from tmuxctl;
//! each pane feeds the same terminal engine as an ordinary SSH shell.
mod framing;
use framing::Framing;
#[cfg(feature = "fuzzing")]
pub use framing::frame_for_fuzzing;
use std::collections::{BTreeMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tether_terminal::{Input, Link, Options, Position, Screen, ScreenSize, Terminal};
use tmuxctl::{Event, Notification};
use tokio::sync::{mpsc, oneshot, watch};

#[derive(Debug, Clone, thiserror::Error)]
#[error("{0}")]
pub struct Error(pub String);
pub type Result<T> = std::result::Result<T, Error>;

/// An ordered duplex byte stream. No SSH or process types cross this boundary.
#[async_trait::async_trait]
pub trait Transport: Send + 'static {
    async fn read(&mut self) -> Result<Option<Vec<u8>>>;
    async fn write(&mut self, bytes: &[u8]) -> Result<()>;
    async fn close(&mut self);
}

/// Quote one argument for tmux's command parser (also safe for a POSIX shell).
pub fn quote(value: &str) -> Result<String> {
    if value.chars().any(|c| c.is_control()) || value.len() > 1024 {
        return Err(Error(
            "Names must be shorter than 1025 bytes and contain no control characters".into(),
        ));
    }
    Ok(format!("'{}'", value.replace('\'', "'\\''")))
}

#[derive(Clone, Debug)]
pub struct Window {
    pub id: u32,
    pub name: String,
    pub active: bool,
    pub width: u16,
    pub height: u16,
}
#[derive(Clone, Debug)]
pub struct PaneInfo {
    pub id: u32,
    pub window: u32,
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
    pub active: bool,
    pub visible: bool,
}
pub struct PaneSnapshot {
    pub info: PaneInfo,
    pub screen: Screen,
}
pub struct Snapshot {
    pub windows: Vec<Window>,
    pub panes: Vec<PaneSnapshot>,
    pub ended: Option<String>,
}
struct Pane {
    info: PaneInfo,
    terminal: Terminal,
}
#[derive(Default)]
struct State {
    windows: Vec<Window>,
    panes: BTreeMap<u32, Pane>,
    ended: Option<String>,
}

/// Typed operations prevent frontend code from constructing control commands.
#[derive(Debug, Clone)]
pub enum Action {
    NewWindow,
    SelectWindow(u32),
    RenameWindow(u32, String),
    CloseWindow(u32),
    SelectPane(u32),
    Split(u32, bool),
    ResizePane(u32, u16, u16),
    ZoomPane(u32),
    ClosePane(u32),
    Resize(u16, u16),
    RenameSession(String),
    EndSession,
    CopyMode(u32),
    ScrollPane(u32, i32),
}
impl Action {
    fn command(&self) -> Result<String> {
        Ok(match self {
            Self::NewWindow => "new-window".into(),
            Self::SelectWindow(id) => format!("select-window -t @{id}"),
            Self::RenameWindow(id, name) => format!("rename-window -t @{id} {}", quote(name)?),
            Self::CloseWindow(id) => format!("kill-window -t @{id}"),
            Self::SelectPane(id) => format!("select-pane -t %{id}"),
            Self::Split(id, horizontal) => {
                format!("split-window {} -t %{id}", if *horizontal { "-h" } else { "-v" })
            }
            Self::ResizePane(id, w, h) => {
                format!("resize-pane -t %{id} -x {} -y {}", w.clamp(&1, &1000), h.clamp(&1, &500))
            }
            Self::ZoomPane(id) => format!("resize-pane -Z -t %{id}"),
            Self::ClosePane(id) => format!("kill-pane -t %{id}"),
            Self::Resize(w, h) => {
                format!("refresh-client -C {},{}", w.clamp(&1, &1000), h.clamp(&1, &500))
            }
            Self::RenameSession(name) => format!("rename-session {}", quote(name)?),
            Self::EndSession => "kill-session".into(),
            Self::CopyMode(id) => format!("copy-mode -e -t %{id}"),
            Self::ScrollPane(id, lines) => {
                let count = lines.unsigned_abs();
                let direction = if *lines > 0 { "scroll-up" } else { "scroll-down" };
                format!("send-keys -X -t %{id} -N {count} {direction}")
            }
        })
    }
}

enum Request {
    Command(String, oneshot::Sender<Result<()>>),
    Input(u32, Vec<u8>),
}

/// A workspace owns one control client. Dropping it detaches, never kills tmux.
pub struct Workspace {
    state: Arc<Mutex<State>>,
    requests: mpsc::Sender<Request>,
    updates: tokio::sync::Mutex<watch::Receiver<u64>>,
    stop: watch::Sender<bool>,
}
impl Workspace {
    pub fn start(transport: impl Transport) -> Self {
        let (requests, inbox) = mpsc::channel(128);
        let (changed, updates) = watch::channel(0);
        let (stop, cancel) = watch::channel(false);
        let state = Arc::new(Mutex::new(State::default()));
        let shared = state.clone();
        tokio::spawn(async move {
            let mut driver = Driver {
                transport: Box::new(transport),
                framing: Framing::new(),
                state: shared.clone(),
                changed,
                dirty: true,
                broken: false,
                replies: VecDeque::new(),
            };
            let mut cancel = cancel;
            let result = tokio::select! {
                result = driver.run(inbox) => result,
                _ = cancel.changed() => Ok(()),
            };
            // Closing the channel detaches this client even if command processing is stalled.
            driver.transport.close().await;
            shared.lock().unwrap().ended = Some(match result {
                Ok(()) => "Detached".into(),
                Err(error) => error.to_string(),
            });
            driver.announce();
        });
        Self { state, requests, updates: tokio::sync::Mutex::new(updates), stop }
    }
    pub fn snapshot(&self) -> Snapshot {
        let state = self.state.lock().unwrap();
        Snapshot {
            windows: state.windows.clone(),
            ended: state.ended.clone(),
            panes: state
                .panes
                .values()
                .map(|p| PaneSnapshot { info: p.info.clone(), screen: p.terminal.screen() })
                .collect(),
        }
    }
    /// What the text at a cell of `pane` names, as for a terminal of its
    /// own. `None` for a pane that is not there.
    pub fn link_at(&self, pane: u32, position: Position) -> Option<Link> {
        self.state.lock().unwrap().panes.get(&pane)?.terminal.link_at(position)
    }
    /// The directory `pane`'s shell last reported, if it reports one.
    pub fn working_directory(&self, pane: u32) -> Option<String> {
        let state = self.state.lock().unwrap();
        state.panes.get(&pane)?.terminal.working_directory().map(str::to_owned)
    }
    pub async fn changed(&self) -> bool {
        if self.state.lock().unwrap().ended.is_some() {
            return false;
        }
        self.updates.lock().await.changed().await.is_ok()
    }
    pub async fn perform(&self, action: Action) -> Result<()> {
        let command = action.command()?;
        let (tx, rx) = oneshot::channel();
        self.requests
            .send(Request::Command(command, tx))
            .await
            .map_err(|_| Error("Workspace ended".into()))?;
        rx.await.map_err(|_| Error("Workspace ended".into()))?
    }
    pub fn send(&self, pane: u32, input: &Input) -> Result<()> {
        let bytes = {
            let mut state = self.state.lock().unwrap();
            let target = state.panes.get_mut(&pane).ok_or_else(|| Error("Pane closed".into()))?;
            target.terminal.encode(input)
        };
        self.write(pane, bytes)
    }
    /// Scrolls a tmux pane through tmux's copy-mode commands. Control-mode
    /// clients do not receive native mouse-wheel events from the terminal.
    pub async fn scroll(&self, pane: u32, lines: i32) -> Result<()> {
        if lines == 0 { return Ok(()); }
        self.perform(Action::CopyMode(pane)).await?;
        self.perform(Action::ScrollPane(pane, lines)).await
    }
    pub fn write(&self, pane: u32, bytes: Vec<u8>) -> Result<()> {
        if bytes.len() > 1024 * 1024 {
            return Err(Error("Paste exceeds 1 MiB".into()));
        }
        self.requests
            .try_send(Request::Input(pane, bytes))
            .map_err(|_| Error("Input queue is full or workspace ended; retry".into()))
    }
    pub fn detach(&self) {
        let _ = self.stop.send(true);
    }
}
impl Drop for Workspace {
    fn drop(&mut self) {
        self.detach();
    }
}

struct Driver {
    transport: Box<dyn Transport>,
    framing: Framing,
    state: Arc<Mutex<State>>,
    changed: watch::Sender<u64>,
    dirty: bool,
    broken: bool,
    replies: VecDeque<(u32, Vec<u8>)>,
}
impl Driver {
    fn announce(&self) {
        self.changed.send_modify(|v| *v = v.wrapping_add(1));
    }
    async fn event(&mut self) -> Result<Event> {
        loop {
            if let Some(event) = self.framing.next() {
                return Ok(event);
            }
            let bytes = self.transport.read().await?.ok_or_else(|| {
                Error("Connection closed. Reconnect to restore this session.".into())
            })?;
            self.framing.push(&bytes)?;
        }
    }
    fn notification(&mut self, notification: Notification) -> Result<()> {
        match notification {
            Notification::Output { pane, bytes }
            | Notification::ExtendedOutput { pane, bytes, .. } => {
                if let Some(target) = self.state.lock().unwrap().panes.get_mut(&pane.0) {
                    target.terminal.feed(&bytes);
                    let reply = target.terminal.take_replies();
                    if !reply.is_empty() {
                        self.replies.push_back((pane.0, reply));
                    }
                }
                self.announce();
            }
            Notification::Exit(reason) => {
                return Err(Error(reason.unwrap_or_else(|| "Session detached or ended".into())));
            }
            Notification::Unknown(_) => {}
            _ => self.dirty = true,
        }
        Ok(())
    }
    async fn command(&mut self, text: &str) -> Result<Vec<String>> {
        match tokio::time::timeout(Duration::from_secs(15), self.command_inner(text)).await {
            Ok(result) => result,
            Err(_) => {
                self.broken = true;
                Err(Error("tmux did not respond within 15 seconds".into()))
            }
        }
    }
    async fn command_inner(&mut self, text: &str) -> Result<Vec<String>> {
        self.transport.write(format!("{text}\n").as_bytes()).await?;
        loop {
            let event = match self.event().await {
                Ok(event) => event,
                Err(error) => {
                    self.broken = true;
                    return Err(error);
                }
            };
            match event {
                Event::Reply(reply) if reply.control => {
                    return if reply.error {
                        Err(Error(reply.output.join("\n")))
                    } else {
                        Ok(reply.output)
                    };
                }
                Event::Reply(_) => {}
                Event::Notification(note) => self.notification(note)?,
            }
        }
    }
    async fn input(&mut self, pane: u32, bytes: &[u8]) -> Result<()> {
        for chunk in bytes.chunks(256) {
            let hex = chunk.iter().map(|b| format!("{b:02x}")).collect::<Vec<_>>().join(" ");
            self.command(&format!("send-keys -H -t %{pane} {hex}")).await?;
        }
        Ok(())
    }
    async fn refresh(&mut self) -> Result<()> {
        self.dirty = false;
        let windows = self.command("list-windows -F '#{window_id} #{window_active} #{window_width} #{window_height} #{window_name}'").await?;
        let mut parsed = Vec::new();
        for line in windows {
            let parts: Vec<_> = line.splitn(5, ' ').collect();
            if parts.len() != 5 {
                return Err(Error("Invalid tmux window metadata".into()));
            }
            parsed.push(Window {
                id: number(parts[0])?,
                active: parts[1] == "1",
                width: dimension(parts[2])?,
                height: dimension(parts[3])?,
                name: parts[4].into(),
            });
        }
        let lines = self.command("list-panes -s -F '#{pane_id} #{window_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height} #{pane_active} #{window_zoomed_flag}'").await?;
        let mut infos = Vec::new();
        for line in lines {
            let p: Vec<_> = line.split(' ').collect();
            if p.len() != 8 {
                return Err(Error("Invalid tmux pane metadata".into()));
            }
            infos.push(PaneInfo {
                id: number(p[0])?,
                window: number(p[1])?,
                x: coordinate(p[2])?,
                y: coordinate(p[3])?,
                width: dimension(p[4])?,
                height: dimension(p[5])?,
                active: p[6] == "1",
                visible: p[7] != "1" || p[6] == "1",
            });
        }
        let cells: usize = infos.iter().map(|p| usize::from(p.width) * usize::from(p.height)).sum();
        if cells > 1_000_000 {
            return Err(Error("Workspace exceeds the visible cell limit".into()));
        }
        if infos.len() > 128 {
            return Err(Error("This workspace exceeds the 128-pane limit".into()));
        }
        let pane_count = infos.len().max(1);
        let mut new = Vec::new();
        {
            let mut state = self.state.lock().unwrap();
            state.windows = parsed;
            state.panes.retain(|id, _| infos.iter().any(|p| p.id == *id));
            for info in infos {
                let size = ScreenSize::new(info.width, info.height);
                if let Some(pane) = state.panes.get_mut(&info.id) {
                    if pane.terminal.size() != size {
                        pane.terminal.resize(size);
                    }
                    pane.info = info;
                } else {
                    new.push(info.id);
                    state.panes.insert(
                        info.id,
                        Pane {
                            info,
                            terminal: Terminal::with_options(
                                size,
                                Options {
                                    scrollback_lines: (100_000
                                        / pane_count
                                        / usize::from(size.columns))
                                    .min(2000),
                                },
                            ),
                        },
                    );
                }
            }
        }
        for id in new {
            // capture-pane is serialized with output on the same control stream.
            // Reset after its reply so output already represented in the capture is not duplicated.
            let alternate =
                self.command(&format!("display-message -p -t %{id} '#{{alternate_on}}'")).await?;
            let capture = match self.command(&format!("capture-pane -p -e -t %{id} -S -2000")).await
            {
                Ok(capture) => capture,
                Err(error) if self.broken => return Err(error),
                Err(_) => {
                    self.dirty = true;
                    continue;
                } // Pane may have closed during attach.
            };
            {
                let mut state = self.state.lock().unwrap();
                if let Some(pane) = state.panes.get_mut(&id) {
                    pane.terminal.feed(b"\x1bc");
                    if alternate.first().is_some_and(|v| v == "1") {
                        pane.terminal.feed(b"\x1b[?1049h");
                    }
                    pane.terminal.feed(capture.join("\r\n").as_bytes());
                    let _ = pane.terminal.take_replies();
                }
            }
            let cursor = self.command(&format!("display-message -p -t %{id} '#{{cursor_x}};#{{cursor_y}};#{{cursor_flag}};#{{keypad_cursor_flag}};#{{bracket_paste_flag}};#{{wrap_flag}}'")).await?;
            let mut state = self.state.lock().unwrap();
            if let Some(pane) = state.panes.get_mut(&id) {
                if let Some(position) = cursor.first() {
                    let values: Vec<_> = position.split(';').collect();
                    if values.len() == 6 {
                        if let (Ok(x), Ok(y)) = (values[0].parse::<u16>(), values[1].parse::<u16>())
                        {
                            pane.terminal.feed(
                                format!("\x1b[{};{}H", y.saturating_add(1), x.saturating_add(1))
                                    .as_bytes(),
                            );
                        }
                        pane.terminal.feed(if values[2] == "1" {
                            b"\x1b[?25h"
                        } else {
                            b"\x1b[?25l"
                        });
                        pane.terminal.feed(if values[3] == "1" {
                            b"\x1b[?1h"
                        } else {
                            b"\x1b[?1l"
                        });
                        pane.terminal.feed(if values[4] == "1" {
                            b"\x1b[?2004h"
                        } else {
                            b"\x1b[?2004l"
                        });
                        pane.terminal.feed(if values[5] == "1" {
                            b"\x1b[?7h"
                        } else {
                            b"\x1b[?7l"
                        });
                    }
                }
                let _ = pane.terminal.take_replies();
            }
        }
        self.announce();
        Ok(())
    }
    async fn run(&mut self, mut requests: mpsc::Receiver<Request>) -> Result<()> {
        self.refresh().await?;
        loop {
            while let Some((pane, bytes)) = self.replies.pop_front() {
                self.input(pane, &bytes).await?;
            }
            if self.dirty {
                self.refresh().await?;
            }
            tokio::select! {
                request = requests.recv() => match request {
                    Some(Request::Command(text, reply)) => {
                        let result = self.command(&text).await.map(|_| ());
                        if self.broken {
                            let error = result.err().unwrap_or_else(|| Error("Control stream ended".into()));
                            let _ = reply.send(Err(error.clone()));
                            return Err(error);
                        }
                        let failed = result.is_err();
                        let _ = reply.send(result);
                        // A failed response can be a recoverable command error. Resynchronise;
                        // a broken transport fails refresh and ends the workspace.
                        self.dirty = true;
                        if failed { self.refresh().await?; }
                    },
                    Some(Request::Input(pane, bytes)) => self.input(pane, &bytes).await?,
                    None => return Ok(()),
                },
                event = self.event() => match event? {
                    Event::Notification(note) => self.notification(note)?,
                    Event::Reply(_) => {},
                }
            }
        }
    }
}
fn number(value: &str) -> Result<u32> {
    value
        .trim_start_matches(['%', '@', '$'])
        .parse()
        .map_err(|_| Error("Invalid tmux identifier".into()))
}
fn coordinate(value: &str) -> Result<u16> {
    value.parse().map_err(|_| Error("Invalid tmux coordinate".into()))
}
fn dimension(value: &str) -> Result<u16> {
    let n = coordinate(value)?;
    if !(1..=1000).contains(&n) {
        return Err(Error("tmux dimensions exceed supported bounds".into()));
    }
    Ok(n)
}
