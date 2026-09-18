//! A remote byte stream bound to a terminal engine.
//!
//! The two halves this crate composes disagree about shape, which is the
//! whole reason a composition layer exists. [`Shell`] is asynchronous and
//! owns itself; [`Terminal`] is synchronous and wants `&mut`. A consumer —
//! especially one behind an FFI seam — is a third party that asks about the
//! screen whenever it repaints, on a thread we do not control.
//!
//! So the shell goes to a task that owns it outright, the terminal goes
//! behind a lock, and the two talk over a channel. The consumer never sees
//! any of that: it asks for a screen and gets one (spec §16).

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use tether_ssh::{Output, Shell, SshError, WindowSize};
use tether_terminal::{Changes, Input, Options, Screen, ScreenSize, Scroll, Terminal, Viewport};

/// What a consumer asked the session to do.
///
/// A queue rather than direct calls because the shell lives in the pump task:
/// a keystroke arriving while the pump is awaiting output must not wait for
/// output to arrive.
enum Command {
    Write(Vec<u8>),
    Resize(ScreenSize),
    Close,
}

/// Why a session stopped.
///
/// Distinguished because a consumer shows different things: a shell that
/// exited normally is a session the person ended, a lost connection is not.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Ending {
    /// The remote shell exited with this status.
    Exited(u32),
    /// The consumer closed the session.
    Closed,
    /// The connection failed underneath us.
    Lost(String),
}

/// State both the pump and the consumer touch.
struct Shared {
    terminal: Mutex<Terminal>,
    /// Bumped on every observable change, so a consumer can wait rather than
    /// poll. The number itself carries no meaning beyond "different".
    generation: AtomicU64,
    changed: tokio::sync::watch::Sender<u64>,
    ending: Mutex<Option<Ending>>,
    /// Recorded when the far side reports it, which is *before* the stream
    /// ends. Kept apart from `ending` because a session whose shell has
    /// exited is still delivering that shell's last output, and treating the
    /// status as the ending would stop a consumer repainting one frame early.
    exit_status: Mutex<Option<u32>>,
}

impl Shared {
    /// Wakes anyone waiting. Called after every mutation of the terminal, and
    /// once more when the session ends so a waiter is never left parked on a
    /// session that will never speak again.
    fn announce(&self) {
        let next = self.generation.fetch_add(1, Ordering::Relaxed) + 1;
        // A send failure means no consumer is listening, which is ordinary.
        let _ = self.changed.send(next);
    }

    fn finish(&self, ending: Ending) {
        {
            let mut slot = self.ending.lock().expect("ending lock poisoned");
            if slot.is_none() {
                *slot = Some(ending);
            }
        }
        self.announce();
    }
}

/// A live terminal session: a remote shell and the screen it is drawing.
///
/// Cloneable handles would let two consumers disagree about who owns the
/// lifetime, so this is not `Clone`. Everything on it takes `&self` — a
/// frontend repaints from one thread and types from another, and making that
/// its problem would push our locking into its code.
pub struct TerminalSession {
    connection: Option<Arc<tether_ssh::Session>>,
    shared: Arc<Shared>,
    commands: tokio::sync::mpsc::UnboundedSender<Command>,
    /// Kept across calls rather than re-subscribed per call: a receiver
    /// created fresh would treat whatever happened before it existed as
    /// already seen, and a change that lands between a repaint and the next
    /// wait would be lost — the screen would then sit stale until the *next*
    /// byte arrived.
    updates: tokio::sync::Mutex<tokio::sync::watch::Receiver<u64>>,
    /// Optional so `close` can take it while `Drop` still has something
    /// to abort. A handle that is `None` has already been awaited.
    pump: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl TerminalSession {
    /// Starts pumping `shell` into a terminal of `size`.
    ///
    /// Takes the shell by value because the session now owns its lifetime;
    /// handing back a shell a caller could also write to would give the far
    /// side two writers and no ordering between them.
    pub fn start(shell: Shell, size: ScreenSize, options: Options) -> Self {
        let (commands, inbox) = tokio::sync::mpsc::unbounded_channel();
        let (changed, updates) = tokio::sync::watch::channel(0);

        let shared = Arc::new(Shared {
            terminal: Mutex::new(Terminal::with_options(size, options)),
            generation: AtomicU64::new(0),
            changed,
            ending: Mutex::new(None),
            exit_status: Mutex::new(None),
        });

        let pump = tokio::spawn(pump(Arc::clone(&shared), shell, inbox));

        Self {
            connection: None,
            shared,
            commands,
            updates: tokio::sync::Mutex::new(updates),
            pump: Mutex::new(Some(pump)),
        }
    }

    pub(crate) fn start_connected(
        shell: Shell,
        size: ScreenSize,
        options: Options,
        connection: Arc<tether_ssh::Session>,
    ) -> Self {
        let mut session = Self::start(shell, size, options);
        session.connection = Some(connection);
        session
    }

    /// A lease on the authenticated connection; closing a shell does not close other channels.
    pub fn connection(&self) -> Option<Arc<tether_ssh::Session>> {
        self.connection.clone()
    }

    /// A snapshot of what the screen looks like now.
    pub fn screen(&self) -> Screen {
        self.shared.terminal.lock().expect("terminal lock poisoned").screen()
    }

    /// What changed since the last time this was called, and clears it.
    ///
    /// A consumer that repaints whole screens can ignore this; one that draws
    /// incrementally reads it instead of diffing (spec §12).
    pub fn take_changes(&self) -> Changes {
        self.shared.terminal.lock().expect("terminal lock poisoned").take_changes()
    }

    /// Moves the viewport over the scrollback.
    ///
    /// Synchronous, like `resize` and for the same reason: a consumer that
    /// scrolls and then repaints must not be handed the screen it had before
    /// it scrolled.
    pub fn scroll(&self, scroll: Scroll) {
        self.shared.terminal.lock().expect("terminal lock poisoned").scroll(scroll);
        self.shared.announce();
    }

    /// Where the viewport is, and how much history is behind it.
    pub fn viewport(&self) -> Viewport {
        self.shared.terminal.lock().expect("terminal lock poisoned").viewport()
    }

    pub fn size(&self) -> ScreenSize {
        self.shared.terminal.lock().expect("terminal lock poisoned").size()
    }

    /// What the far side set the window title to.
    pub fn title(&self) -> String {
        self.shared.terminal.lock().expect("terminal lock poisoned").title().to_owned()
    }

    /// `Some` once the session has stopped, and why.
    pub fn ending(&self) -> Option<Ending> {
        self.shared.ending.lock().expect("ending lock poisoned").clone()
    }

    /// The status the remote shell exited with, if it has.
    ///
    /// Available before [`Self::ending`] is, because the far side reports the
    /// status and then keeps writing.
    pub fn exit_status(&self) -> Option<u32> {
        *self.shared.exit_status.lock().expect("exit status lock poisoned")
    }

    /// Waits until something changed, returning `false` once the session has
    /// ended and never will again.
    ///
    /// The shape a repaint loop wants: `while session.changed().await { .. }`
    /// costs nothing while the screen is still and wakes on the first byte.
    pub async fn changed(&self) -> bool {
        if self.ending().is_some() {
            return false;
        }
        let mut updates = self.updates.lock().await;
        // A closed channel means the pump is gone, which is an ending even if
        // it never managed to record one.
        updates.changed().await.is_ok() && self.ending().is_none()
    }

    /// Turns something the person did into bytes and sends them.
    ///
    /// Encoding happens here, under the same lock that holds the modes it
    /// depends on: the far side can switch application cursor mode between a
    /// key press and its encoding, and reading the mode separately would
    /// encode an arrow key against a mode that had already changed.
    pub fn send(&self, input: &Input) -> Result<(), SessionError> {
        let bytes = {
            let mut terminal = self.shared.terminal.lock().expect("terminal lock poisoned");

            // Typing returns to the live screen, the way every terminal does.
            // A keystroke whose echo lands somewhere off-screen reads as a
            // terminal that ignored it — so this belongs here, above the
            // engine, rather than being left for each frontend to remember.
            terminal.scroll(Scroll::Live);
            terminal.encode(input)
        };
        if bytes.is_empty() {
            // A key with no encoding is not an error — F21 exists on keyboards
            // and on no terminal.
            return Ok(());
        }
        self.write(bytes)
    }

    /// Sends bytes as they are, for a consumer that has its own encoding.
    pub fn write(&self, bytes: Vec<u8>) -> Result<(), SessionError> {
        self.commands.send(Command::Write(bytes)).map_err(|_| SessionError::Ended)
    }

    /// Tells both halves the window changed size.
    ///
    /// Both, in that order, and not by the consumer calling two APIs: a
    /// terminal resized without telling the far side leaves full-screen
    /// programs drawing to the old geometry.
    pub fn resize(&self, size: ScreenSize) -> Result<(), SessionError> {
        // The engine resizes here rather than in the pump. Queueing both
        // halves made `size()` report the old geometry until the pump next
        // ran, so a consumer that resized and then laid out its view laid it
        // out against a screen that no longer existed.
        {
            let mut terminal = self.shared.terminal.lock().expect("terminal lock poisoned");
            terminal.resize(size);
        }
        self.shared.announce();

        // Telling the far side stays asynchronous: it is a write, and a
        // write can block.
        self.commands.send(Command::Resize(size)).map_err(|_| SessionError::Ended)
    }

    /// Asks the session to end without waiting for it to finish.
    ///
    /// Exists for a consumer that holds the session behind a shared handle
    /// and so cannot consume it — a frontend closing a window, where there is
    /// nothing useful to await and nowhere to report a failure to.
    pub fn close_in_place(&self) {
        // A closed channel means the pump already stopped, which is the
        // outcome being asked for.
        let _ = self.commands.send(Command::Close);
    }

    /// Ends the session and waits for the pump to stop.
    pub async fn close(self) -> Result<(), SessionError> {
        // A closed channel means the pump already stopped, which is what was
        // being asked for.
        let _ = self.commands.send(Command::Close);

        let pump = self.pump.lock().expect("pump lock poisoned").take();
        match pump {
            Some(pump) => pump.await.map_err(|error| SessionError::Failed(error.to_string())),
            None => Ok(()),
        }
    }
}

impl Drop for TerminalSession {
    fn drop(&mut self) {
        // Dropping the handle must not leave a task holding a socket open.
        // The pump also observes the command channel closing, but aborting is
        // what makes it prompt rather than eventual. Already `None` when
        // `close` ran, in which case the task is finished anyway.
        if let Some(pump) = self.pump.lock().expect("pump lock poisoned").take() {
            pump.abort();
        }
    }
}

impl std::fmt::Debug for TerminalSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TerminalSession")
            .field("size", &self.size())
            .field("ending", &self.ending())
            .finish()
    }
}

/// What can go wrong once a session is running.
///
/// Short, because by this point the connection exists: the interesting
/// failures already happened during [`crate::dial`].
#[derive(Debug, Clone, thiserror::Error, PartialEq, Eq)]
pub enum SessionError {
    #[error("the session has ended")]
    Ended,
    #[error("the session failed: {0}")]
    Failed(String),
}

/// Carries bytes between the shell and the terminal until one of them stops.
async fn pump(
    shared: Arc<Shared>,
    mut shell: Shell,
    mut inbox: tokio::sync::mpsc::UnboundedReceiver<Command>,
) {
    loop {
        tokio::select! {
            // Biased so a queued keystroke is sent before we park on output
            // again. Unbiased, a busy screen would starve typing.
            biased;

            command = inbox.recv() => {
                match command {
                    Some(Command::Write(bytes)) => {
                        if let Err(error) = shell.write(bytes).await {
                            shared.finish(Ending::Lost(error.to_string()));
                            return;
                        }
                    }
                    Some(Command::Resize(size)) => {
                        // The engine already resized, in `resize`. This arm
                        // is only the half that has to cross the network.
                        let window = WindowSize::new(size.columns as u32, size.rows as u32);
                        if let Err(error) = shell.resize(window).await {
                            shared.finish(Ending::Lost(error.to_string()));
                            return;
                        }
                    }
                    Some(Command::Close) | None => {
                        let _ = shell.close().await;
                        shared.finish(Ending::Closed);
                        return;
                    }
                }
            }

            output = shell.next_output() => {
                match output {
                    Some(Output::Stdout(bytes)) | Some(Output::Stderr(bytes)) => {
                        // stderr is merged deliberately: a PTY gives the far
                        // side one stream, and a shell that writes to stderr
                        // expects it interleaved on the same screen. Keeping
                        // them apart here would reorder what the person sees.
                        let replies = {
                            let mut terminal =
                                shared.terminal.lock().expect("terminal lock poisoned");
                            terminal.feed(&bytes);
                            terminal.take_replies()
                        };
                        shared.announce();

                        // The terminal answers some sequences itself — cursor
                        // position reports, device attributes. A program that
                        // asked and got no answer waits forever, so these go
                        // back out before anything else is read.
                        if !replies.is_empty()
                            && let Err(error) = shell.write(replies).await
                        {
                            shared.finish(Ending::Lost(error.to_string()));
                            return;
                        }
                    }
                    Some(Output::Exited(status)) => {
                        // Recorded, not acted on. Output can still arrive
                        // after the status, so ending the session here would
                        // drop a program's last line.
                        *shared.exit_status.lock().expect("exit status lock poisoned") =
                            Some(status);
                    }
                    None => {
                        // The stream is the authority on when it is over. An
                        // exit status we saw earlier says the shell ended on
                        // its own terms; without one, the channel went away
                        // underneath us.
                        let status = *shared.exit_status.lock().expect("exit status lock poisoned");
                        shared.finish(match status {
                            Some(status) => Ending::Exited(status),
                            None => Ending::Lost(
                                SshError::Disconnected { cause: "the shell closed".into() }
                                    .to_string(),
                            ),
                        });
                        return;
                    }
                }
            }
        }
    }
}
