//! Hosts in the window, as the Mac `TabSet` keeps them: the strip shows the
//! current host's terminals; choosing a host shows its last terminal, or
//! dials it when it has none; a login's questions go up one at a time; a
//! terminal is connecting, asking, connected, down, or ended.

use std::sync::Arc;

use gpui::{Context, Window};
use tether_desktop::hosts::{self, Host};
use tether_desktop::login;
use tether_desktop::split::PaneId;
use tether_desktop::workspaces::WorkspaceId;
use tether_ffi::{Session, SessionEnding};
use tether_ui::{HostRow, Mark, Presence};
use tokio::sync::mpsc;

use crate::connect::{self, Asker, Question};
use crate::platform::{self, TerminalLayer};
use crate::workspace::Desktop;

/// Where a terminal is in its life (`SessionTab.stage`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Stage {
    Connecting,
    /// A question of its login is up.
    Asking,
    Connected,
    /// Failed to connect, or lost: the reason, and the way back is Reconnect.
    Down(String),
    Ended,
}

impl Stage {
    /// `stateName`.
    pub(crate) fn name(&self) -> &'static str {
        match self {
            Self::Connecting => "Connecting",
            Self::Asking => "Needs authentication",
            Self::Connected => "Connected",
            Self::Down(_) => "Disconnected",
            Self::Ended => "Ended",
        }
    }
}

/// The library, this machine first; empty or unreadable lists only it.
pub(crate) fn listed() -> Vec<Host> {
    let library =
        hosts::library_path().and_then(|path| hosts::load(&path).ok()).unwrap_or_default();
    std::iter::once(Host::local()).chain(library).collect()
}

impl Desktop {
    /// Puts each login's questions to the window, in the order they come.
    pub(crate) fn listen(
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> mpsc::UnboundedSender<Question> {
        let (sender, mut questions) = mpsc::unbounded_channel::<Question>();
        cx.spawn_in(window, async move |this, cx| {
            while let Some(question) = questions.recv().await {
                let shown = this.update_in(cx, |this, window, cx| {
                    this.set_stage(question.pane, Stage::Asking, cx);
                    platform::ask(window, &question.dialog)
                });
                let Ok(reply) = shown else { return };
                let reply = reply.await.ok().flatten();
                let _ = this
                    .update(cx, |this, cx| this.set_stage(question.pane, Stage::Connecting, cx));
                let _ = question.answer.send(reply);
            }
        })
        .detach();
        sender
    }

    fn set_stage(&mut self, pane: Option<PaneId>, stage: Stage, cx: &mut Context<Self>) {
        let Some(pane) = pane else { return };
        // Only a login in progress moves between connecting and asking.
        if matches!(self.stages.get(&pane), Some(Stage::Connecting | Stage::Asking)) {
            self.stages.insert(pane, stage);
            self.sync(cx);
        }
    }

    pub(crate) fn asker(&self, pane: Option<PaneId>) -> Asker {
        Asker { pane, questions: self.questions.clone() }
    }

    pub(crate) fn current_host(&self) -> Host {
        self.hosts.iter().find(|host| host.id == self.current).cloned().unwrap_or_else(Host::local)
    }

    /// The current host's terminals, in strip order.
    pub(crate) fn strip(&self) -> Vec<PaneId> {
        self.workspaces
            .strip()
            .into_iter()
            .filter(|id| self.host_of.get(id) == Some(&self.current))
            .collect()
    }

    /// The selected terminal, when it is on the current host.
    pub(crate) fn shown(&self) -> Option<PaneId> {
        self.workspaces.selected().filter(|id| self.host_of.get(id) == Some(&self.current))
    }

    pub(crate) fn is_live(&self, id: PaneId) -> bool {
        self.stages.get(&id) == Some(&Stage::Connected)
    }

    fn host_is_live(&self, host: &str) -> bool {
        self.host_of.iter().any(|(id, of)| of == host && self.is_live(*id))
    }

    /// What the host bar shows for the selected terminal (`statusMark`,
    /// `statusColor`).
    pub(crate) fn status(&self) -> (Option<Mark>, Presence) {
        let stage = self.shown().and_then(|id| self.stages.get(&id));
        let mark = match stage {
            Some(Stage::Connecting) => Some(Mark::Connecting),
            Some(Stage::Asking) => Some(Mark::Asking),
            Some(Stage::Down(_)) => Some(Mark::Reconnect),
            Some(Stage::Ended) => Some(Mark::Ended),
            _ => None,
        };
        let presence = match stage {
            Some(Stage::Connected) => Presence::Live,
            Some(Stage::Down(_)) => Presence::Down,
            _ => Presence::Idle,
        };
        (mark, presence)
    }

    /// The picker's rows: the current host, other live hosts, then the idle
    /// ones under a hairline; `⌘1`… by library order.
    pub(crate) fn host_rows(&self) -> (Vec<HostRow>, Vec<String>) {
        let order: Vec<(usize, &Host)> = self.hosts.iter().enumerate().collect();
        let current = order.iter().filter(|(_, host)| host.id == self.current);
        let live =
            order.iter().filter(|(_, host)| host.id != self.current && self.host_is_live(&host.id));
        let idle = order
            .iter()
            .filter(|(_, host)| host.id != self.current && !self.host_is_live(&host.id));
        let mut rows = Vec::new();
        let mut ids = Vec::new();
        let mut seen_live = false;
        for (group, members) in
            [(0, current.collect::<Vec<_>>()), (1, live.collect()), (2, idle.collect())]
        {
            for (position, (index, host)) in members.into_iter().enumerate() {
                let divider = group == 2 && position == 0 && seen_live;
                seen_live = true;
                rows.push(HostRow {
                    name: host.display_name(),
                    caption: if host.is_local() { "Local machine".into() } else { host.address() },
                    live: self.host_is_live(&host.id),
                    current: host.id == self.current,
                    shortcut: (*index < 9).then(|| *index as u8 + 1),
                    divider_above: divider,
                });
                ids.push(host.id.clone());
            }
        }
        (rows, ids)
    }

    /// Choosing a host (`HostPicker.choose`, ⌘1…): back to its last terminal,
    /// or a new one when it has none.
    pub(crate) fn choose_host(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(host) = self.hosts.iter().find(|host| host.id == id).cloned() else { return };
        if let Some(shown) = self.shown() {
            self.last_by_host.insert(self.current.clone(), shown);
        }
        self.current = host.id.clone();
        let strip = self.strip();
        match self
            .last_by_host
            .get(&host.id)
            .copied()
            .filter(|id| strip.contains(id))
            .or(strip.first().copied())
        {
            Some(terminal) => self.workspaces = self.workspaces.selecting(terminal),
            None => self.open(None, window, cx),
        }
        self.sync(cx);
    }

    /// A terminal on a host away from this machine: another channel on a
    /// live terminal's lease, or a login — asking for a password first only
    /// when nothing else could log in (`passwordSource`).
    pub(crate) fn open_remote(
        &mut self,
        host: Host,
        page: Option<WorkspaceId>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(problem) = host.route_problem() {
            self.notice("Could Not Connect", &problem, window);
            return;
        }
        let lease = self
            .host_of
            .iter()
            .filter(|(id, of)| **of == host.id && self.is_live(**id))
            .find_map(|(id, _)| self.panes.get(id).map(|pane| pane.session.clone()))
            .filter(|session| session.connection().is_some());
        let runtime = self.runtime.clone();
        let asker = self.asker(None);
        cx.spawn_in(window, async move |this, cx| {
            if let Some(lease) = lease
                && let Ok(Some(session)) = runtime.spawn(connect::on_lease(lease)).await
            {
                let _ = this.update_in(cx, |this, window, cx| {
                    let id = this.adopt(&host, page);
                    if let Ok(layer) = TerminalLayer::attach(window) {
                        this.attach(id, session, layer, cx);
                    }
                });
                return;
            }
            let probe = host.clone();
            let master = runtime
                .spawn(async move { connect::master_running(&probe).await })
                .await
                .unwrap_or(false);
            let password = if master || !connect::key_files(&host).is_empty() {
                None
            } else {
                match asker.ask(login::password(&host.display_name(), &host.address())).await {
                    Some(reply) => reply.values.into_iter().next(),
                    // Cancelling leaves no tab behind.
                    None => return,
                }
            };
            let _ = this.update_in(cx, |this, window, cx| {
                let id = this.adopt(&host, page);
                this.dial(id, host, password, master, window, cx);
            });
        })
        .detach();
    }

    /// Another terminal beside `beside` on its lease; a login when it has none.
    pub(crate) fn split_remote(
        &mut self,
        id: PaneId,
        beside: PaneId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let host = self.current_host();
        let lease = self
            .panes
            .get(&beside)
            .map(|pane| pane.session.clone())
            .filter(|_| self.is_live(beside));
        self.stages.insert(id, Stage::Connecting);
        let runtime = self.runtime.clone();
        cx.spawn_in(window, async move |this, cx| {
            let session = match lease {
                Some(lease) => runtime.spawn(connect::on_lease(lease)).await.ok().flatten(),
                None => None,
            };
            let _ = this.update_in(cx, |this, window, cx| {
                match (session, TerminalLayer::attach(window)) {
                    (Some(session), Ok(layer)) => this.attach(id, session, layer, cx),
                    _ => this.dial(id, host, None, false, window, cx),
                }
            });
        })
        .detach();
    }

    /// A new terminal for `host` in the strip, selected.
    fn adopt(&mut self, host: &Host, page: Option<WorkspaceId>) -> PaneId {
        let id = self.new_terminal_id();
        self.host_of.insert(id, host.id.clone());
        self.current = host.id.clone();
        self.workspaces = self.workspaces.adopting(id, page);
        id
    }

    /// Logs `id` in. A failure asks Close or Retry; a refused login asks
    /// for the password again before retrying.
    pub(crate) fn dial(
        &mut self,
        id: PaneId,
        host: Host,
        password: Option<String>,
        master: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.stages.insert(id, Stage::Connecting);
        self.sync(cx);
        let layer = TerminalLayer::attach(window);
        let asker = self.asker(Some(id));
        let job = self.runtime.spawn(connect::dial(
            host.clone(),
            password.clone(),
            master,
            asker.clone(),
        ));
        cx.spawn_in(window, async move |this, cx| {
            let dialled = match job.await {
                Ok(dialled) => dialled,
                Err(_) => return,
            };
            let failure = match (dialled, layer) {
                (Ok(session), Ok(layer)) => {
                    let _ = this.update(cx, |this, cx| this.attach(id, session, layer, cx));
                    return;
                }
                (Ok(session), Err(error)) => {
                    session.close();
                    connect::Failure { reason: error, refused: false }
                }
                (Err(failure), _) => failure,
            };
            let screen = this.update(cx, |this, cx| {
                this.stages.insert(id, Stage::Down(failure.reason.clone()));
                this.sync(cx);
                this.panes.contains_key(&id)
            });
            let Ok(keeps_screen) = screen else { return };
            let question =
                login::could_not_connect(&host.display_name(), &failure.reason, keeps_screen);
            let Some(_) = asker.ask(question).await else {
                if !keeps_screen {
                    let _ = this.update(cx, |this, cx| {
                        this.close_terminal(id);
                        this.sync(cx);
                    });
                }
                return;
            };
            let password = if failure.refused {
                match asker.ask(login::password(&host.display_name(), &host.address())).await {
                    Some(reply) => reply.values.into_iter().next(),
                    None => {
                        let _ = this.update(cx, |this, cx| {
                            this.close_terminal(id);
                            this.sync(cx);
                        });
                        return;
                    }
                }
            } else {
                password
            };
            let _ = this.update_in(cx, |this, window, cx| {
                this.dial(id, host, password, master, window, cx)
            });
        })
        .detach();
    }

    /// The status bar's Reconnect ("Restart" here): the same terminal again.
    pub(crate) fn reconnect(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.shown() else { return };
        if !matches!(self.stages.get(&id), Some(Stage::Down(_))) {
            return;
        }
        let host = self.current_host();
        if let Some(mut pane) = self.panes.remove(&id) {
            pane.close();
        }
        if host.is_local() {
            self.start_shell(id, window, cx);
        } else {
            self.dial(id, host, None, false, window, cx);
        }
    }

    /// How a session that stopped is shown: a shell that exited ended; a
    /// connection that went away is down, with its reason.
    pub(crate) fn stopped(&mut self, id: PaneId, session: &Arc<Session>, cx: &mut Context<Self>) {
        let stage = match session.ending() {
            Some(SessionEnding::Lost { cause }) => {
                Stage::Down(format!("The connection was lost. {cause}"))
            }
            _ => Stage::Ended,
        };
        self.stages.insert(id, stage);
        self.sync(cx);
    }

    /// Something that has already happened, and OK (`Dialog.notice`).
    fn notice(&self, title: &str, message: &str, window: &mut Window) {
        let dialog = tether_desktop::dialog::Dialog::new(
            title,
            Some(message.to_owned()),
            Vec::new(),
            vec![tether_desktop::dialog::Action::cancel("OK")],
        );
        // Nothing waits on OK: the sheet stays until it is dismissed.
        drop(platform::ask(window, &dialog));
    }
}
