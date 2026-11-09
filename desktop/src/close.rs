//! Closing what may still be working: the Mac `requestClose` and
//! `requestCloseWorkspace`.
//!
//! An ended shell closes at once. A live one is listed first (two seconds
//! at most); idle, it closes; otherwise the question names it, says what
//! may stop, and the verb is the close itself — destructive, no Return, the
//! same chord again confirms. One close is asked at a time.

use std::sync::Arc;
use std::time::Duration;

use gpui::{Context, Window};
use tether_desktop::activity::{self, Activity};
use tether_desktop::dialog::{Dialog, Role, Shortcut};
use tether_desktop::split::PaneId;
use tether_desktop::workspaces::WorkspaceId;
use tether_ffi::{CancellationToken, Session};

use crate::platform;
use crate::workspace::Desktop;

/// How long a listing may take before nothing is claimed about the shell.
const CHECK: Duration = Duration::from_secs(2);

impl Desktop {
    /// ⌘W, a chip's close box.
    pub(crate) fn request_close(
        &mut self,
        id: PaneId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing {
            return;
        }
        let Some(session) = self.live(id) else {
            self.close_terminal(id);
            self.sync(cx);
            return;
        };
        self.closing = true;
        let listing = self.runtime.spawn(check(session));
        cx.spawn_in(window, async move |this, cx| {
            let activity = listing.await.unwrap_or(Activity::Unknown);
            let _ = this.update_in(cx, |this, window, cx| {
                let Some(message) = activity.close_message() else {
                    this.closing = false;
                    this.close_terminal(id);
                    this.sync(cx);
                    return;
                };
                let name = this.titles.get(&id).cloned().unwrap_or_default();
                let title =
                    if name.is_empty() { "Close?".to_owned() } else { format!("Close {name}?") };
                let dialog = Dialog::confirm(
                    title,
                    Some(message),
                    "Close Terminal",
                    Role::Destructive,
                    vec![Shortcut::Command('w')],
                );
                this.confirm(dialog, window, cx, move |this, cx| {
                    this.close_terminal(id);
                    this.sync(cx);
                });
            });
        })
        .detach();
    }

    /// ⌥⌘W: every terminal on the page, each listed; one question for all.
    pub(crate) fn request_close_tab(
        &mut self,
        page: WorkspaceId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(workspace) = self.workspaces.pages().iter().find(|p| p.id == page).cloned() else {
            return;
        };
        if self.closing {
            return;
        }
        self.closing = true;
        let live: Vec<(PaneId, Arc<Session>)> = workspace
            .terminals
            .iter()
            .filter_map(|id| self.live(*id).map(|session| (*id, session)))
            .collect();
        let listings: Vec<_> = live
            .into_iter()
            .map(|(id, session)| (id, self.runtime.spawn(check(session))))
            .collect();
        cx.spawn_in(window, async move |this, cx| {
            let mut found = Vec::new();
            for (id, listing) in listings {
                found.push((id, listing.await.unwrap_or(Activity::Unknown)));
            }
            let _ = this.update_in(cx, |this, window, cx| {
                let notes: Vec<String> = found
                    .iter()
                    .filter_map(|(id, activity)| {
                        let name = this.titles.get(id).cloned().unwrap_or_default();
                        activity.close_message().map(|message| format!("{name}: {message}"))
                    })
                    .collect();
                if notes.is_empty() {
                    this.closing = false;
                    this.close_page(page);
                    this.sync(cx);
                    return;
                }
                let dialog = Dialog::confirm(
                    format!("Close {}?", workspace.name),
                    Some(notes.join("\n\n")),
                    "Close Tab",
                    Role::Destructive,
                    vec![Shortcut::CommandOption('w')],
                );
                this.confirm(dialog, window, cx, move |this, cx| {
                    this.close_page(page);
                    this.sync(cx);
                });
            });
        })
        .detach();
    }

    /// Asks, and runs `close` only on the destructive verb.
    fn confirm(
        &mut self,
        dialog: Dialog,
        window: &mut Window,
        cx: &mut Context<Self>,
        close: impl FnOnce(&mut Self, &mut Context<Self>) + 'static,
    ) {
        let verb = dialog.actions.iter().position(|action| action.role == Role::Destructive);
        let answer = platform::ask(window, &dialog);
        cx.spawn(async move |this, cx| {
            let chosen = answer.await.ok().flatten().map(|reply| reply.action);
            let _ = this.update(cx, |this, cx| {
                this.closing = false;
                if chosen.is_some() && chosen == verb {
                    close(this, cx);
                }
            });
        })
        .detach();
    }

    /// The session of a terminal whose shell is still running.
    fn live(&self, id: PaneId) -> Option<Arc<Session>> {
        if !self.is_live(id) {
            return None;
        }
        self.panes.get(&id).map(|pane| pane.session.clone())
    }
}

/// `ShellActivity.check`: the process table, read over the terminal's own
/// lease, for the terminal's tty.
async fn check(session: Arc<Session>) -> Activity {
    let (Some(connection), Some(tty)) = (session.connection(), session.terminal_name()) else {
        return Activity::Unknown;
    };
    let terminal = activity::device(&tty).unwrap_or(tty);
    let listing = connection.execute(activity::LIST_COMMAND.to_owned(), CancellationToken::new());
    match tokio::time::timeout(CHECK, listing).await {
        Ok(Ok(output)) if output.status == Some(0) => {
            activity::parse(&String::from_utf8_lossy(&output.stdout), &terminal)
        }
        _ => Activity::Unknown,
    }
}
