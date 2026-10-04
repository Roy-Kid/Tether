//! A live session, as a Swift consumer holds it.
//!
//! The object is a handle, never a pointer: UniFFI owns the allocation and a
//! consumer holds a reference-counted proxy (spec §13). Nothing here can
//! panic across the seam — every fallible path returns [`TetherError`], and
//! the lock guards are scoped so a poisoned lock cannot unwind into Swift.

use std::sync::Arc;

use tether_core::local_shell::Command;
use tether_core::terminal::{Options, ScreenSize, Scroll};
use tether_core::{Credential, Dial, Ending, Local, SshClient, TerminalSession};

use crate::input::{Resolved, TerminalInput};
use crate::keys::{ForeignUnlocker, PassphrasePrompter};
use crate::screen::ScreenFrame;
use crate::{AuthPrompt, InteractivePrompter, TetherError};

/// What a host key looks like to an application being asked to trust it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct HostIdentity {
    pub host: String,
    pub port: u16,
    pub algorithm: String,
    /// The `SHA256:…` form a person compares against what their
    /// administrator published.
    pub fingerprint: String,
}

/// Asks the application whether a host may be talked to.
///
/// Upward, like the prompter, and for the same reason: only the application
/// knows what it has stored and what it may ask a person. It is called
/// during the handshake, before any credential exists on the wire — which is
/// the point of asking at all (spec §18).
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait HostTrust: Send + Sync {
    async fn trusts(&self, host: HostIdentity) -> bool;
}

/// Adapts the foreign trait to the one `tether-ssh` defines.
struct ForeignVerifier(Arc<dyn HostTrust>);

#[async_trait::async_trait]
impl tether_core::ssh::HostVerifier for ForeignVerifier {
    async fn verify(
        &self,
        endpoint: &tether_core::ssh::Endpoint,
        key: &tether_core::ssh::HostKey,
    ) -> tether_core::ssh::Verdict {
        let identity = HostIdentity {
            host: endpoint.host.clone(),
            port: endpoint.port,
            algorithm: key.algorithm.clone(),
            fingerprint: key.fingerprint.clone(),
        };
        if self.0.trusts(identity).await {
            tether_core::ssh::Verdict::Trusted
        } else {
            tether_core::ssh::Verdict::Rejected
        }
    }
}

/// Adapts the foreign prompter to the one `tether-ssh` defines.
struct ForeignPrompter(Arc<dyn InteractivePrompter>);

#[async_trait::async_trait]
impl tether_core::ssh::Prompter for ForeignPrompter {
    async fn answer(&self, challenge: &tether_core::ssh::Challenge) -> Option<Vec<String>> {
        let prompts = challenge
            .prompts
            .iter()
            .map(|prompt| AuthPrompt { text: prompt.text.clone(), echo: prompt.echo })
            .collect();

        let answers = self.0.answer(challenge.instruction.clone(), prompts).await;

        // An empty vector is how the foreign side says "the person declined".
        // Declining is a decision, not a rejected credential (spec §10). It
        // can only mean that: a round with nothing to answer never reaches a
        // prompter.
        if answers.is_empty() { None } else { Some(answers) }
    }
}

/// A credential to offer, in the order they are given.
#[derive(uniffi::Enum)]
pub enum Secret {
    Password {
        password: String,
    },
    /// PEM text, so a key held in a keychain item never has to be written to
    /// a file to be used.
    ///
    /// A key protected by a passphrase is unlocked with `passphrase` when one
    /// is given, and otherwise by asking `unlock` — only once the server has
    /// said it would take the key. With neither, it is left out and named in
    /// the error if the login fails.
    PrivateKey {
        pem: String,
        passphrase: Option<String>,
        unlock: Option<Arc<dyn PassphrasePrompter>>,
    },
    /// Answers whatever the server asks, for as many rounds as it asks.
    Interactive {
        prompter: Arc<dyn InteractivePrompter>,
    },
}

/// Where to connect and as whom.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Destination {
    pub host: String,
    pub port: u16,
    pub user: String,
    /// What the far side will see in `$TERM`. It decides which sequences
    /// remote programs emit, so it must describe what this frontend can
    /// actually draw.
    pub term: String,
    pub columns: u16,
    pub rows: u16,
    pub scrollback_lines: u32,
    pub history: Option<Arc<crate::SessionHistory>>,
}

/// Connects, authenticates and opens a shell.
///
/// Async all the way: a handshake is network-bound and a prompt is
/// person-bound, and neither may block a UI thread (spec §13).
///
/// `async_runtime = "tokio"` is load-bearing, not decoration. Without it
/// UniFFI polls the future on its own executor, where there is no reactor —
/// and the first socket this touches panics with "there is no reactor
/// running". It reaches a consumer as an opaque `rustPanic`, so the cost of
/// forgetting it is a crash with no useful error.
#[uniffi::export(async_runtime = "tokio")]
pub async fn connect(
    destination: Destination,
    trust: Arc<dyn HostTrust>,
    secrets: Vec<Secret>,
) -> Result<Arc<Session>, TetherError> {
    let size = ScreenSize::new(destination.columns, destination.rows);

    let credentials = secrets
        .into_iter()
        .map(|secret| match secret {
            Secret::Password { password } => Credential::Password(password),
            Secret::PrivateKey { pem, passphrase, unlock } => Credential::PrivateKey {
                pem,
                passphrase,
                unlock: unlock.map(|prompter| {
                    Arc::new(ForeignUnlocker(prompter)) as Arc<dyn tether_core::ssh::KeyUnlocker>
                }),
            },
            Secret::Interactive { prompter } => {
                Credential::Interactive(Arc::new(ForeignPrompter(prompter)))
            }
        })
        .collect();

    let session = Dial::new(
        tether_core::ssh::Endpoint::new(destination.host, destination.port),
        destination.user,
    )
    .verifier(Arc::new(ForeignVerifier(trust)))
    .term(destination.term)
    .size(size)
    .options(Options { scrollback_lines: destination.scrollback_lines as usize })
    .history(destination.history.map(|h| h.inner.clone()))
    .connect(credentials)
    .await?;

    Ok(Arc::new(Session { inner: session }))
}

/// Cancellation-aware entry point; the original connect remains source compatible.
#[uniffi::export(async_runtime = "tokio")]
pub async fn connect_cancellable(
    destination: Destination,
    trust: Arc<dyn HostTrust>,
    secrets: Vec<Secret>,
    cancellation: Arc<crate::CancellationToken>,
) -> Result<Arc<Session>, TetherError> {
    tokio::select! {
        biased;
        _ = cancellation.inner.cancelled() => Err(TetherError::Cancelled),
        result = connect(destination, trust, secrets) => result,
    }
}

/// Where a shell on this machine starts, and what it should believe it is
/// running on.
///
/// No host, no user and no credential, and that absence is the design rather
/// than an omission: there is no handshake with the machine the application
/// is already running on. What comes back is the same [`Session`] a remote
/// connection returns, so nothing above this point has two paths to maintain.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LocalShell {
    /// Where the shell starts. The person's home directory when absent,
    /// which is what a shell would have chosen anyway.
    pub directory: Option<String>,
    /// What the shell will see in `$TERM`. It decides which sequences
    /// programs emit, so it must describe what this frontend can actually
    /// draw.
    pub term: String,
    pub columns: u16,
    pub rows: u16,
    pub scrollback_lines: u32,
    pub history: Option<Arc<crate::SessionHistory>>,
}

/// Whether this platform lets an application start a shell.
///
/// A question, so a consumer can leave the feature out of its interface
/// rather than offer one that always refuses. iOS answers `false`: there is
/// no `fork`/`exec` outside the sandbox, and that is the system's decision,
/// not a setting.
#[uniffi::export]
pub fn local_shell_available() -> bool {
    tether_core::local_shell::is_available()
}

/// Opens a shell on this machine.
///
/// `async` although nothing here waits on a network: the session it returns
/// spawns a pump task, and `async_runtime = "tokio"` is what puts this call
/// inside a runtime that has one. Without it UniFFI polls on its own
/// executor, where there is no reactor, and the failure reaches a consumer as
/// an opaque `rustPanic`.
#[uniffi::export(async_runtime = "tokio")]
pub async fn open_local(shell: LocalShell) -> Result<Arc<Session>, TetherError> {
    let size = ScreenSize::new(shell.columns, shell.rows);

    let mut local = Local::running(Command::login_shell())
        .term(shell.term)
        .size(size)
        .options(Options { scrollback_lines: shell.scrollback_lines as usize })
        .history(shell.history.map(|h| h.inner.clone()));

    // A local shell starts in the user's home, regardless of the working
    // directory inherited by an app launched from Finder or the Dock.
    let directory = shell
        .directory
        .filter(|path| !path.is_empty())
        .or_else(|| std::env::var("HOME").ok().filter(|path| path.starts_with('/')));
    if let Some(directory) = directory {
        local = local.directory(directory);
    }

    Ok(Arc::new(Session { inner: local.open().await? }))
}

/// Whether `ssh -O check` says a multiplexing master is already running
/// for this config alias.
///
/// A live master is a handshake that has already been spent. The
/// application attaches through OpenSSH instead of offering credentials
/// again.
#[uniffi::export(async_runtime = "tokio")]
pub async fn ssh_master_running(target: String) -> bool {
    SshClient::new(target).master_running().await
}

/// Opens a shell by asking the OpenSSH client, typically a ControlMaster.
#[uniffi::export(async_runtime = "tokio")]
pub async fn connect_over_ssh_client(
    target: String,
    shell: LocalShell,
) -> Result<Arc<Session>, TetherError> {
    let size = ScreenSize::new(shell.columns, shell.rows);
    let session = SshClient::new(target)
        .connect_recorded(
            shell.term,
            size,
            Options { scrollback_lines: shell.scrollback_lines as usize },
            shell.history.map(|h| h.inner.clone()),
        )
        .await
        .map_err(|error| TetherError::ShellRefused { cause: error.cause })?;
    Ok(Arc::new(Session { inner: session }))
}

/// Cancellation-aware attach; the original remains source compatible.
#[uniffi::export(async_runtime = "tokio")]
pub async fn connect_over_ssh_client_cancellable(
    target: String,
    shell: LocalShell,
    cancellation: Arc<crate::CancellationToken>,
) -> Result<Arc<Session>, TetherError> {
    tokio::select! {
        biased;
        _ = cancellation.inner.cancelled() => Err(TetherError::Cancelled),
        result = connect_over_ssh_client(target, shell) => result,
    }
}

/// Where to put the viewport over the scrollback.
///
/// Named by intent, not by line arithmetic: how much a page is depends on the
/// screen, and a frontend that computed it would have to ask for the size and
/// could get a different answer than the engine uses.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ScrollTo {
    /// Positive goes back into history, negative comes forward.
    Lines {
        count: i32,
    },
    PageUp,
    PageDown,
    Oldest,
    Live,
}

/// Why a session stopped.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SessionEnding {
    Exited { status: u32 },
    Closed,
    Lost { cause: String },
}

/// One colour, as the far side will be told it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ColorValue {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
}

/// What a consumer draws with, for the questions the far side asks.
///
/// Not the screen: cells still report colour *names*, and what `red` looks
/// like stays the consumer's business (spec §12). This is the answer to
/// `OSC 11 ; ?` — "what is your background?" — which only whoever draws can
/// give. A program that asks and hears nothing assumes the terminal is dark
/// and paints its own theme over every cell, which is how a light window
/// ends up black.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TerminalPalette {
    pub foreground: ColorValue,
    pub background: ColorValue,
    pub cursor: ColorValue,
    /// The sixteen ANSI colours: eight normal, then eight bright. Any other
    /// length is refused rather than padded — a palette that is not sixteen
    /// colours is a mistake on the consumer's side, not a default.
    pub ansi: Vec<ColorValue>,
}

impl TerminalPalette {
    fn resolve(self) -> Result<tether_core::terminal::Palette, TetherError> {
        use tether_core::terminal::Rgb;
        let ansi: Vec<Rgb> =
            self.ansi.into_iter().map(|c| Rgb::new(c.red, c.green, c.blue)).collect();
        let ansi: [Rgb; 16] = ansi.try_into().map_err(|_| TetherError::Protocol {
            cause: "A palette needs sixteen ANSI colours".into(),
        })?;
        Ok(tether_core::terminal::Palette {
            foreground: Rgb::new(self.foreground.red, self.foreground.green, self.foreground.blue),
            background: Rgb::new(self.background.red, self.background.green, self.background.blue),
            cursor: Rgb::new(self.cursor.red, self.cursor.green, self.cursor.blue),
            ansi,
        })
    }
}

/// A live terminal session.
#[derive(uniffi::Object)]
pub struct Session {
    inner: TerminalSession,
}

impl Session {
    pub(crate) fn wrap(inner: TerminalSession) -> Arc<Self> {
        Arc::new(Self { inner })
    }
}

/// Tokio again, for the same reason: `await_change` parks on a watch channel
/// that the pump task wakes, and the pump only exists inside a runtime.
#[uniffi::export(async_runtime = "tokio")]
impl Session {
    pub fn connection(&self) -> Option<Arc<crate::RemoteConnection>> {
        self.inner.connection().map(|inner| Arc::new(crate::RemoteConnection { inner }))
    }

    /// The local shell's tty path, for matching tmux clients to this tab.
    pub fn terminal_name(&self) -> Option<String> {
        self.inner.terminal_name().map(str::to_owned)
    }

    /// The local shell's live working directory, if available.
    pub fn current_directory(&self) -> Option<String> {
        self.inner.current_directory()
    }

    /// Tells the engine what this consumer draws with, so that a program
    /// asking for a colour is answered.
    ///
    /// Settable at any time: a person switching their window to light is the
    /// same question being asked again. `None` goes back to saying nothing.
    pub fn set_palette(&self, palette: Option<TerminalPalette>) -> Result<(), TetherError> {
        let resolved = palette.map(TerminalPalette::resolve).transpose()?;
        self.inner.set_palette(resolved);
        Ok(())
    }

    /// Everything needed to draw the screen once.
    pub fn frame(&self) -> ScreenFrame {
        ScreenFrame::of(&self.inner.screen(), self.inner.title())
    }

    /// What changed since the last call. Rows that did not change are absent.
    pub fn update(&self) -> crate::FrameUpdate {
        crate::FrameUpdate::from_delta(&self.inner.take_frame_delta())
    }

    pub fn checkpoint_history(&self) {
        self.inner.checkpoint_history();
    }

    pub fn history_error(&self) -> Option<String> {
        self.inner.history_error()
    }

    /// Drops scrollback above `keep` lines for the rest of this session.
    pub fn release_history(&self, keep: u32) {
        self.inner.release_history(keep as usize);
    }

    /// Stops reading the far side until [`resume`](Self::resume).
    pub fn pause(&self) {
        self.inner.pause();
    }

    /// Reads the far side again.
    pub fn resume(&self) {
        self.inner.resume();
    }

    /// What the text at a cell names, if anything, and where it is drawn.
    /// Asked when a person points, not every frame.
    pub fn link_at(&self, row: u16, column: u16) -> Option<crate::TerminalLink> {
        self.inner
            .link_at(tether_core::terminal::Position::new(row, column))
            .map(crate::TerminalLink::from)
    }

    /// The directory the shell last reported, if it reports one.
    pub fn working_directory(&self) -> Option<String> {
        self.inner.working_directory()
    }

    /// Waits until the screen changed, returning `false` once the session has
    /// ended and never will again.
    ///
    /// A frontend's repaint loop is `while await session.awaitChange() { … }`:
    /// it costs nothing while the screen is still, and wakes on the first
    /// byte. Polling on a timer would either lag or burn a core.
    pub async fn await_change(&self) -> bool {
        self.inner.changed().await
    }

    /// Sends something the person did.
    ///
    /// Encoding happens on the Rust side, against the modes the *remote*
    /// program set — which is why a frontend sends a key rather than bytes
    /// (spec §12).
    pub fn send(&self, input: TerminalInput) -> Result<(), TetherError> {
        match input.resolve() {
            Resolved::Encoded(input) => self.inner.send(&input).map_err(Into::into),
            // Nothing to send is not an error: a key with no text and no
            // encoding is a key this terminal has no bytes for.
            Resolved::Literal(text) if text.is_empty() => Ok(()),
            Resolved::Literal(text) => self.inner.write(text.into_bytes()).map_err(Into::into),
        }
    }

    /// Moves the viewport over the scrollback.
    ///
    /// Nothing to report: the engine clamps at both ends, so a wheel at the
    /// end of its travel is a no-op rather than an error a frontend has to
    /// handle on every notch.
    pub fn scroll(&self, to: ScrollTo) {
        self.inner.scroll(match to {
            ScrollTo::Lines { count } => Scroll::Lines(count),
            ScrollTo::PageUp => Scroll::PageUp,
            ScrollTo::PageDown => Scroll::PageDown,
            ScrollTo::Oldest => Scroll::Oldest,
            ScrollTo::Live => Scroll::Live,
        });
    }

    /// Tells both the engine and the far side that the window changed size.
    pub fn resize(&self, columns: u16, rows: u16) -> Result<(), TetherError> {
        self.inner.resize(ScreenSize::new(columns, rows)).map_err(Into::into)
    }

    /// `null` while the session is still running.
    pub fn ending(&self) -> Option<SessionEnding> {
        self.inner.ending().map(|ending| match ending {
            Ending::Exited(status) => SessionEnding::Exited { status },
            Ending::Closed => SessionEnding::Closed,
            Ending::Lost(cause) => SessionEnding::Lost { cause },
        })
    }

    /// Ends the session. Idempotent, because a frontend closing a window
    /// cannot easily know whether the far side got there first.
    pub fn close(&self) {
        self.inner.close_in_place();
    }
}
