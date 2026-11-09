//! Dialling a host from the library: the Mac `SessionTab.dial` and
//! `AuthenticationCoordinator`.
//!
//! The credentials go in the Mac order — keys, the password a person typed,
//! then whatever the server asks — and every question a login has goes to
//! the window through [`Asker`], one at a time. A host key is checked
//! against the pins and `known_hosts` first; a new one is asked about, a
//! changed one refused without a question.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tether_desktop::dialog::{Dialog, Reply};
use tether_desktop::hosts::{self, Host};
use tether_desktop::known_hosts::{self, Verdict};
use tether_desktop::login::{self, Prompt};
use tether_desktop::split::PaneId;
use tether_ffi::{
    AuthPrompt, CancellationToken, Destination, HostIdentity, HostTrust, InteractivePrompter,
    LocalShell, LockedKey, PassphrasePrompter, Secret, Session,
};
use tokio::sync::{mpsc, oneshot};

/// What the far side is told it is talking to; the Mac app's.
pub const TERM: &str = "xterm-256color";
pub const SCROLLBACK: u32 = 10_000;
/// A question nobody answers ends the login (`IdentityModel` "No answer in time.").
const ANSWER: Duration = Duration::from_secs(90);

/// A question for the window, and where its answer goes.
pub struct Question {
    pub pane: Option<PaneId>,
    pub dialog: Dialog,
    pub answer: oneshot::Sender<Option<Reply>>,
}

/// Puts a login's questions to the window, from any thread.
#[derive(Clone)]
pub struct Asker {
    pub pane: Option<PaneId>,
    pub questions: mpsc::UnboundedSender<Question>,
}

impl Asker {
    /// The reply, or `None` when the person declined, the window went away,
    /// or nobody answered in time.
    pub async fn ask(&self, dialog: Dialog) -> Option<Reply> {
        let (answer, reply) = oneshot::channel();
        let affirm = dialog.clone();
        self.questions.send(Question { pane: self.pane, dialog, answer }).ok()?;
        let reply = tokio::time::timeout(ANSWER, reply).await.ok()?.ok()??;
        affirm.affirms(&reply).then_some(reply)
    }
}

/// Why a dial failed, and whether it was the login that was refused.
pub struct Failure {
    pub reason: String,
    pub refused: bool,
}

/// What `ssh` is told to reach: the label, or the hostname (`sshTarget`).
pub fn ssh_target(host: &Host) -> String {
    let label = host.label.trim();
    if label.is_empty() { host.hostname.clone() } else { label.to_owned() }
}

/// The key files offered, by name: the host's own, or the default identities.
pub fn key_files(host: &Host) -> Vec<(String, PathBuf)> {
    let Some(home) = dirs::home_dir() else { return Vec::new() };
    let files = match &host.key_path {
        Some(path) => vec![match path.strip_prefix("~/") {
            Some(rest) => home.join(rest),
            None => PathBuf::from(path),
        }],
        None => hosts::default_keys(&home),
    };
    files
        .into_iter()
        .filter(|path| path.is_file())
        .map(|path| {
            (path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(), path)
        })
        .collect()
}

fn shell() -> LocalShell {
    LocalShell {
        directory: None,
        term: TERM.into(),
        columns: 80,
        rows: 24,
        scrollback_lines: SCROLLBACK,
        shell: None,
        history: None,
    }
}

/// A running ControlMaster for this host is a login already spent.
pub async fn master_running(host: &Host) -> bool {
    tether_ffi::ssh_master_running(ssh_target(host)).await
}

/// Logs in and opens a shell. `password` is one a person just typed.
pub async fn dial(
    host: Host,
    password: Option<String>,
    master: bool,
    asker: Asker,
) -> Result<Arc<Session>, Failure> {
    if let Some(problem) = host.route_problem() {
        return Err(Failure { reason: problem, refused: false });
    }
    let fail = |error: tether_ffi::TetherError, keys: &[String], refusal: Option<String>| Failure {
        refused: login::refused(&error),
        reason: refusal.unwrap_or_else(|| login::describe(&error, keys)),
    };
    if master {
        return tether_ffi::connect_over_ssh_client_cancellable(
            ssh_target(&host),
            shell(),
            CancellationToken::new(),
        )
        .await
        .map_err(|error| fail(error, &[], None));
    }
    let mut names = Vec::new();
    let mut secrets = Vec::new();
    for (name, path) in key_files(&host) {
        let Ok(pem) = std::fs::read_to_string(&path) else { continue };
        let unlock = Arc::new(Unlocker { asker: asker.clone(), name: name.clone() });
        secrets.push(Secret::PrivateKey { pem, passphrase: None, unlock: Some(unlock) });
        names.push(name);
    }
    if let Some(password) = password.clone().filter(|p| !p.is_empty()) {
        secrets.push(Secret::Password { password });
    }
    let prompter = Arc::new(Prompter { asker: asker.clone(), password });
    secrets.push(Secret::Interactive { prompter });
    let refusal = Arc::new(Mutex::new(None));
    let trust = Arc::new(Trust { asker, refusal: refusal.clone() });
    let destination = Destination {
        host: host.hostname.clone(),
        port: host.port,
        user: host.username.clone(),
        term: TERM.into(),
        columns: 80,
        rows: 24,
        scrollback_lines: SCROLLBACK,
        history: None,
    };
    tether_ffi::connect_cancellable(
        destination,
        trust,
        secrets,
        Vec::new(),
        CancellationToken::new(),
    )
    .await
    .map_err(|error| {
        let refusal = refusal.lock().ok().and_then(|reason| reason.clone());
        fail(error, &names, refusal)
    })
}

/// `KnownHosts.verdict`, and the Trust question for a key never seen.
struct Trust {
    asker: Asker,
    /// Why a changed key was refused, for the failure the person is shown.
    refusal: Arc<Mutex<Option<String>>>,
}

#[async_trait::async_trait]
impl HostTrust for Trust {
    async fn trusts(&self, host: HostIdentity) -> bool {
        let pins_path = known_hosts::pins_path();
        let pins = pins_path.as_deref().map(known_hosts::read).unwrap_or_default();
        let system =
            known_hosts::system_path().as_deref().map(known_hosts::read).unwrap_or_default();
        match known_hosts::verdict(
            &pins,
            &system,
            &host.host,
            host.port,
            &host.algorithm,
            &host.fingerprint,
        ) {
            Verdict::Trusted => true,
            Verdict::Changed(reason) => {
                if let Ok(mut refusal) = self.refusal.lock() {
                    *refusal = Some(reason);
                }
                false
            }
            Verdict::Unknown => {
                let question =
                    login::trust(&host.host, host.port, &host.algorithm, &host.fingerprint);
                if self.asker.ask(question).await.is_none() {
                    return false;
                }
                if let Some(path) = pins_path {
                    let current = known_hosts::read(&path);
                    let pins = known_hosts::remembered(
                        &current,
                        &host.host,
                        host.port,
                        &host.algorithm,
                        &host.fingerprint,
                    );
                    if let Err(error) = std::fs::create_dir_all(path.parent().unwrap_or(&path))
                        .and_then(|()| std::fs::write(&path, pins))
                    {
                        eprintln!("tether-desktop: known hosts: {error}");
                    }
                }
                true
            }
        }
    }
}

/// Keyboard-interactive rounds: the typed password answers a round that
/// asks only for the account password; anything else is asked.
struct Prompter {
    asker: Asker,
    password: Option<String>,
}

#[async_trait::async_trait]
impl InteractivePrompter for Prompter {
    async fn answer(&self, instruction: String, prompts: Vec<AuthPrompt>) -> Vec<String> {
        let prompts: Vec<Prompt> =
            prompts.into_iter().map(|p| Prompt { text: p.text, echo: p.echo }).collect();
        if let Some(password) = &self.password
            && !prompts.is_empty()
            && prompts.iter().all(login::is_account_password)
        {
            return vec![password.clone(); prompts.len()];
        }
        match self.asker.ask(login::prompts(&prompts, &instruction, None)).await {
            Some(reply) => reply.values,
            // An empty answer is a decline.
            None => Vec::new(),
        }
    }
}

/// A key's passphrase, asked by the key's file name.
struct Unlocker {
    asker: Asker,
    name: String,
}

#[async_trait::async_trait]
impl PassphrasePrompter for Unlocker {
    async fn passphrase(&self, key: LockedKey, attempt: u32) -> Option<String> {
        let question = login::passphrase(&self.name, key.fingerprint.as_deref(), attempt);
        self.asker.ask(question).await.and_then(|reply| reply.values.into_iter().next())
    }
}

/// Another terminal on a host already logged in to: a second channel on its
/// lease (`TabSet.open(host, on:)`).
pub async fn on_lease(session: Arc<Session>) -> Option<Arc<Session>> {
    let connection = session.connection()?;
    connection
        .open_shell(TERM.into(), 80, 24, SCROLLBACK, None, CancellationToken::new())
        .await
        .ok()
}
