//! A byte stream bound to a terminal engine.
//!
//! The two halves this crate composes disagree about shape, which is the
//! whole reason a composition layer exists. A [`Producer`] is asynchronous
//! and owns itself; [`Terminal`] is synchronous and wants `&mut`. A consumer
//! — especially one behind an FFI seam — is a third party that asks about the
//! screen whenever it repaints, on a thread we do not control.
//!
//! So the shell goes to a task that owns it outright, the terminal goes
//! behind a lock, and the two talk over a channel. The consumer never sees
//! any of that: it asks for a screen and gets one (spec §16).

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use tether_terminal::{
    Changes, FrameDelta, Input, Link, Options, Palette, Position, Screen, ScreenSize, Scroll,
    Terminal, Viewport,
};

use crate::connection::Connection;
use crate::producer::{Output, Producer};

/// What a consumer asked the session to do.
///
/// A queue rather than direct calls because the producer lives in the pump
/// task: a keystroke arriving while the pump is awaiting output must not wait
/// for output to arrive.
enum Command {
    Write(Vec<u8>),
    Resize(ScreenSize),
    /// Stop reading the producer. Bytes stay in the kernel buffer, which is
    /// bounded, instead of being copied into the grid while nobody is looking.
    Pause,
    Resume,
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
    /// The stream failed underneath us.
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
    /// Recorded when the producer reports it, which is *before* the stream
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

/// A live terminal session: a shell and the screen it is drawing.
///
/// One type, whichever producer it reads from. A shell on the far side of the
/// world and a shell on this machine differ in how they are *started* and in
/// nothing else, so nothing here — and nothing above here — has a branch for
/// which one it got (spec §8).
///
/// Cloneable handles would let two consumers disagree about who owns the
/// lifetime, so this is not `Clone`. Everything on it takes `&self` — a
/// frontend repaints from one thread and types from another, and making that
/// its problem would push our locking into its code.
pub struct TerminalSession {
    connection: Option<Connection>,
    terminal_name: Option<String>,
    local_process_id: Option<u32>,
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
    /// Starts pumping `producer` into a terminal of `size`.
    ///
    /// Takes the producer by value because the session now owns its lifetime;
    /// handing back a stream a caller could also write to would give the far
    /// end two writers and no ordering between them.
    pub fn start<P: Producer>(producer: P, size: ScreenSize, options: Options) -> Self {
        let (commands, inbox) = tokio::sync::mpsc::unbounded_channel();
        let (changed, updates) = tokio::sync::watch::channel(0);

        let shared = Arc::new(Shared {
            terminal: Mutex::new(Terminal::with_options(size, options)),
            generation: AtomicU64::new(0),
            changed,
            ending: Mutex::new(None),
            exit_status: Mutex::new(None),
        });

        let pump = tokio::spawn(pump(Arc::clone(&shared), producer, inbox));

        Self {
            connection: None,
            terminal_name: None,
            local_process_id: None,
            shared,
            commands,
            updates: tokio::sync::Mutex::new(updates),
            pump: Mutex::new(Some(pump)),
        }
    }

    /// Starts a session that can also run a second command where its shell
    /// is running.
    pub(crate) fn start_with<P: Producer>(
        producer: P,
        size: ScreenSize,
        options: Options,
        connection: Connection,
        terminal_name: Option<String>,
        local_process_id: Option<u32>,
    ) -> Self {
        let mut session = Self::start(producer, size, options);
        session.connection = Some(connection);
        session.terminal_name = terminal_name;
        session.local_process_id = local_process_id;
        session
    }

    /// A lease on whatever can run a second command where this session's
    /// shell is running.
    ///
    /// `None` for a session that has no such thing. Asking is how a consumer
    /// finds out, rather than by knowing which kind of session it holds —
    /// which is the point: a feature built on this works over SSH and on this
    /// machine without being written twice.
    pub fn connection(&self) -> Option<Connection> {
        self.connection.clone()
    }

    /// The terminal name for a local shell, if its PTY exposes one.
    pub fn terminal_name(&self) -> Option<&str> {
        self.terminal_name.as_deref()
    }

    /// The local shell's live working directory when the backend can read it.
    pub fn current_directory(&self) -> Option<String> {
        self.local_process_id.and_then(tether_local::current_directory)
    }

    /// Tells the engine what this consumer draws with.
    ///
    /// Only used to answer the far side's colour queries — `OSC 11 ; ?` is
    /// "what is your background?", and a program that hears nothing assumes
    /// a dark one and paints its own theme over every cell. The screen's own
    /// colours are still names, chosen by whoever draws them (spec §12).
    ///
    /// Settable at any time, because appearance is: a person switching their
    /// window to light is the same question asked again.
    pub fn set_palette(&self, palette: Option<Palette>) {
        self.shared.terminal.lock().expect("terminal lock poisoned").set_palette(palette);
    }

    /// A snapshot of what the screen looks like now.
    pub fn screen(&self) -> Screen {
        self.shared.terminal.lock().expect("terminal lock poisoned").screen()
    }

    /// Damage since the last call, and only the rows that damage names.
    pub fn take_frame_delta(&self) -> FrameDelta {
        self.shared.terminal.lock().expect("terminal lock poisoned").take_frame_delta()
    }

    /// Text a program asked to copy onto the local clipboard since the last
    /// call. The consumer writes it; this session has no clipboard of its own.
    pub fn take_clipboard(&self) -> Option<String> {
        self.shared.terminal.lock().expect("terminal lock poisoned").take_clipboard()
    }

    /// Drops scrollback above `keep` lines for the rest of the session.
    pub fn release_history(&self, keep: usize) {
        {
            let mut terminal = self.shared.terminal.lock().expect("terminal lock poisoned");
            terminal.release_history(keep);
        }
        self.shared.announce();
    }

    /// Stops the pump reading until [`resume`](Self::resume). Close still ends it.
    pub fn pause(&self) {
        let _ = self.commands.send(Command::Pause);
    }

    /// Reads the producer again. Output that arrived while paused is delivered then.
    pub fn resume(&self) {
        let _ = self.commands.send(Command::Resume);
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

    /// The directory the far side's shell last reported, if it reports one.
    pub fn working_directory(&self) -> Option<String> {
        self.shared
            .terminal
            .lock()
            .expect("terminal lock poisoned")
            .working_directory()
            .map(str::to_owned)
    }

    /// What the text at `position` names — a hyperlink, a web address, or
    /// something shaped like a path — and where it is drawn. Shape only:
    /// whether a path exists is asked of the [`Connection`], not here.
    ///
    /// [`Connection`]: crate::Connection
    pub fn link_at(&self, position: Position) -> Option<Link> {
        self.shared.terminal.lock().expect("terminal lock poisoned").link_at(position)
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

/// Carries bytes between the producer and the terminal until one of them
/// stops.
async fn pump<P: Producer>(
    shared: Arc<Shared>,
    mut producer: P,
    mut inbox: tokio::sync::mpsc::UnboundedReceiver<Command>,
) {
    let mut paused = false;
    loop {
        tokio::select! {
            // Biased so a queued keystroke is sent before we park on output
            // again. Unbiased, a busy screen would starve typing.
            biased;

            command = inbox.recv() => {
                match command {
                    Some(Command::Write(bytes)) => {
                        if let Err(error) = producer.write(bytes).await {
                            shared.finish(Ending::Lost(error.to_string()));
                            return;
                        }
                    }
                    Some(Command::Resize(size)) => {
                        // The engine already resized, in `resize`. This arm
                        // is only the half the producer has to carry.
                        if let Err(error) = producer.resize(size).await {
                            shared.finish(Ending::Lost(error.to_string()));
                            return;
                        }
                    }
                    Some(Command::Pause) => paused = true,
                    Some(Command::Resume) => paused = false,
                    Some(Command::Close) | None => {
                        producer.close().await;
                        shared.finish(Ending::Closed);
                        return;
                    }
                }
            }

            output = producer.next_output(), if !paused => {
                match output {
                    Some(Output::Bytes(bytes)) => {
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
                            && let Err(error) = producer.write(replies).await
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
                            None => Ending::Lost("the shell closed".to_owned()),
                        });
                        return;
                    }
                }
            }
        }
    }
}
