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

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, TryLockError};

use tether_terminal::{
    Changes, FrameDelta, Input, Link, Modes, Options, Palette, Position, Screen, ScreenSize,
    Scroll, Terminal, Viewport,
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
    history: Option<crate::history::HistoryArchive>,
    history_stopped: AtomicBool,
    history_generation: AtomicU64,
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
    /// The modes as of the last bytes fed, kept apart from the terminal so a
    /// keystroke is encoded without waiting for a parse in progress. A `cat`
    /// flood holds the terminal for a chunk at a time, and the thread that
    /// types is usually the one that draws.
    modes: Mutex<Modes>,
    /// A keystroke asked for the live screen while the terminal was busy.
    /// Whoever takes the terminal next moves there first.
    scroll_live: AtomicBool,
    /// What a program last asked to copy (`OSC 52`), moved out of the engine
    /// as it is fed. A consumer polls for it on every repaint, hidden tabs
    /// included, and that poll should not queue behind the parser.
    clipboard: Mutex<Option<String>>,
}

impl Shared {
    /// The terminal, with any pending return to the live screen applied, so
    /// what the caller reads or changes comes after the keystroke that asked
    /// for it.
    fn lock(&self) -> MutexGuard<'_, Terminal> {
        self.settle(self.terminal.lock().expect("terminal lock poisoned"))
    }

    fn settle<'a>(&self, mut terminal: MutexGuard<'a, Terminal>) -> MutexGuard<'a, Terminal> {
        if self.scroll_live.swap(false, Ordering::AcqRel) {
            terminal.scroll(Scroll::Live);
        }
        terminal
    }

    /// Returns the viewport to the live screen now if the terminal is free,
    /// or leaves it to whoever holds it.
    fn request_live(&self) {
        self.scroll_live.store(true, Ordering::Release);
        match self.terminal.try_lock() {
            Ok(terminal) => drop(self.settle(terminal)),
            Err(TryLockError::WouldBlock) => {}
            Err(TryLockError::Poisoned(_)) => panic!("terminal lock poisoned"),
        }
    }

    /// What the pump does under the lock after every feed: publish the
    /// modes the next keystroke is encoded against, and move out a copy
    /// request.
    fn absorb(&self, terminal: &mut Terminal) {
        *self.modes.lock().expect("modes lock poisoned") = terminal.modes();
        if let Some(text) = terminal.take_clipboard() {
            *self.clipboard.lock().expect("clipboard lock poisoned") = Some(text);
        }
    }

    fn checkpoint_history(&self) {
        if let Some(history) = &self.history {
            // Keep capture and commit ordered with synchronous resize/close.
            let mut terminal = self.lock();
            if self.history_stopped.load(Ordering::Relaxed) {
                return;
            }
            let generation = self.generation.load(Ordering::Relaxed);
            if generation == self.history_generation.load(Ordering::Relaxed) {
                return;
            }
            self.history_generation.store(generation, Ordering::Relaxed);
            let events = terminal.take_history_events();
            let screen = terminal.history_screen();
            history.write(events, screen);
        }
    }

    /// Wakes anyone waiting. Called after every mutation of the terminal, and
    /// once more when the session ends so a waiter is never left parked on a
    /// session that will never speak again.
    fn announce(&self) {
        let next = self.generation.fetch_add(1, Ordering::Relaxed) + 1;
        // A send failure means no consumer is listening, which is ordinary.
        let _ = self.changed.send(next);
    }

    fn finish(&self, ending: Ending) {
        self.checkpoint_history();
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
        Self::start_recorded(producer, size, options, None)
    }

    pub fn start_recorded<P: Producer>(
        producer: P,
        size: ScreenSize,
        options: Options,
        history: Option<crate::history::HistoryArchive>,
    ) -> Self {
        let (commands, inbox) = tokio::sync::mpsc::unbounded_channel();
        let (changed, updates) = tokio::sync::watch::channel(0);

        let mut terminal = Terminal::with_options(size, options);
        if let Some(archive) = &history {
            if let Err(error) = archive.begin_session() {
                archive.record_error(error.to_string());
            }
            match archive.tail(options.scrollback_lines) {
                Ok(rows) => {
                    let restored = terminal.restore_history(&rows);
                    if !rows.is_empty() {
                        let mut events = vec![tether_terminal::HistoryEvent::Truncate(rows.len())];
                        events.extend(restored.into_iter().map(tether_terminal::HistoryEvent::Row));
                        archive.write(events, terminal.history_screen());
                    }
                }
                Err(error) => archive.record_error(error.to_string()),
            }
            terminal.record_history();
        }
        let modes = terminal.modes();
        let shared = Arc::new(Shared {
            terminal: Mutex::new(terminal),
            history,
            history_stopped: AtomicBool::new(false),
            history_generation: AtomicU64::new(u64::MAX),
            generation: AtomicU64::new(0),
            changed,
            ending: Mutex::new(None),
            exit_status: Mutex::new(None),
            modes: Mutex::new(modes),
            scroll_live: AtomicBool::new(false),
            clipboard: Mutex::new(None),
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
        history: Option<crate::history::HistoryArchive>,
    ) -> Self {
        let mut session = Self::start_recorded(producer, size, options, history);
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
    pub fn local_process_id(&self) -> Option<u32> {
        self.local_process_id
    }

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
        self.shared.lock().set_palette(palette);
    }

    /// A snapshot of what the screen looks like now.
    pub fn screen(&self) -> Screen {
        self.shared.lock().screen()
    }

    /// Damage since the last call, and only the rows that damage names.
    pub fn take_frame_delta(&self) -> FrameDelta {
        self.shared.lock().take_frame_delta()
    }

    /// Text a program asked to copy onto the local clipboard since the last
    /// call. The consumer writes it; this session has no clipboard of its own.
    ///
    /// Does not touch the terminal: the pump moves a copy out as it feeds.
    pub fn take_clipboard(&self) -> Option<String> {
        self.shared.clipboard.lock().expect("clipboard lock poisoned").take()
    }

    /// Drops scrollback above `keep` lines for the rest of the session.
    pub fn release_history(&self, keep: usize) {
        {
            let mut terminal = self.shared.lock();
            terminal.release_history(keep);
        }
        self.shared.announce();
    }

    /// Stops the pump reading until [`resume`](Self::resume). Close still ends it.
    ///
    /// Output backs up at the producer meanwhile. Over SSH that is the
    /// channel's buffer and then the socket: once they are full the server's
    /// writes stall, its keepalives go unanswered, and it drops the client.
    /// Pause for moments, not for as long as a window is hidden.
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
        self.shared.lock().take_changes()
    }

    /// Moves the viewport over the scrollback.
    ///
    /// Synchronous, like `resize` and for the same reason: a consumer that
    /// scrolls and then repaints must not be handed the screen it had before
    /// it scrolled.
    pub fn scroll(&self, scroll: Scroll) {
        self.shared.lock().scroll(scroll);
        self.shared.announce();
    }

    /// Where the viewport is, and how much history is behind it.
    pub fn viewport(&self) -> Viewport {
        self.shared.lock().viewport()
    }

    pub fn size(&self) -> ScreenSize {
        self.shared.lock().size()
    }

    /// What the far side set the window title to.
    pub fn title(&self) -> String {
        self.shared.lock().title().to_owned()
    }

    /// The directory the far side's shell last reported, if it reports one.
    pub fn working_directory(&self) -> Option<String> {
        self.shared.lock().working_directory().map(str::to_owned)
    }

    /// What the text at `position` names — a hyperlink, a web address, or
    /// something shaped like a path — and where it is drawn. Shape only:
    /// whether a path exists is asked of the [`Connection`], not here.
    ///
    /// [`Connection`]: crate::Connection
    pub fn link_at(&self, position: Position) -> Option<Link> {
        self.shared.lock().link_at(position)
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
    /// Never waits for the parser. The modes are the ones published after
    /// the last bytes fed — a single point in the stream, so an arrow key is
    /// never encoded against half of a mode change — and the key goes on the
    /// same queue as every other write, so keys keep their order.
    pub fn send(&self, input: &Input) -> Result<(), SessionError> {
        // Typing returns to the live screen, the way every terminal does.
        // A keystroke whose echo lands somewhere off-screen reads as a
        // terminal that ignored it — so this belongs here, above the
        // engine, rather than being left for each frontend to remember.
        self.shared.request_live();
        let bytes = {
            let modes = *self.shared.modes.lock().expect("modes lock poisoned");
            input.encode(modes)
        };
        if bytes.is_empty() {
            // A key with no encoding is not an error — F21 exists on keyboards
            // and on no terminal.
            return Ok(());
        }
        self.write(bytes)
    }

    /// Send wheel events to mouse-aware applications, or scroll local history.
    pub fn wheel(
        &self,
        lines: i32,
        row: u16,
        column: u16,
        local: bool,
    ) -> Result<(), SessionError> {
        let bytes = {
            let mut terminal = self.shared.terminal.lock().expect("terminal lock poisoned");
            let bytes = if local { None } else { terminal.encode_wheel(lines, row, column) };
            if bytes.is_none() {
                terminal.scroll(Scroll::Lines(lines.saturating_neg()));
            }
            bytes
        };
        match bytes {
            Some(bytes) if !bytes.is_empty() => self.write(bytes),
            _ => Ok(()),
        }
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
            let mut terminal = self.shared.lock();
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
    /// Commit output already parsed before releasing the consumer's handle.
    pub fn checkpoint_history(&self) {
        self.shared.checkpoint_history();
    }

    pub fn history_error(&self) -> Option<String> {
        self.shared.history.as_ref().and_then(|history| history.error())
    }

    pub fn close_in_place(&self) {
        {
            let mut terminal = self.shared.lock();
            if !self.shared.history_stopped.swap(true, Ordering::Relaxed)
                && let Some(history) = &self.shared.history
            {
                history.write(terminal.take_history_events(), terminal.history_screen());
                history.flush();
            }
        }
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
        self.close_in_place();
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
    let mut checkpoint = tokio::time::interval(std::time::Duration::from_millis(250));
    checkpoint.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
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

            _ = checkpoint.tick(), if shared.history.is_some() => {
                let shared = Arc::clone(&shared);
                let _ = tokio::task::spawn_blocking(move || shared.checkpoint_history()).await;
            }

            output = producer.next_output(), if !paused => {
                match output {
                    Some(Output::Bytes(bytes)) => {
                        let replies = if shared.history.is_some() {
                            let worker = Arc::clone(&shared);
                            match tokio::task::spawn_blocking(move || {
                                let mut replies = Vec::new();
                                for chunk in bytes.chunks(8192) {
                                    let mut terminal = worker.lock();
                                    terminal.feed(chunk);
                                    worker.absorb(&mut terminal);
                                    if !worker.history_stopped.load(Ordering::Relaxed) {
                                        if terminal.pending_history_events() >= 256 {
                                            let events = terminal.take_history_events();
                                            worker.history.as_ref().unwrap().write(events, terminal.history_screen());
                                        }
                                    } else { terminal.take_history_events(); }
                                    replies.extend(terminal.take_replies());
                                }
                                replies
                            }).await {
                                Ok(replies) => replies,
                                Err(error) => { shared.finish(Ending::Lost(error.to_string())); return; }
                            }
                        } else {
                            let mut terminal = shared.lock();
                            terminal.feed(&bytes);
                            shared.absorb(&mut terminal);
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

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tether_terminal::Key;

    use super::*;
    use crate::producer::ProducerError;

    /// A shell that prints what the test sends it and records what it is
    /// sent, in order.
    struct Probe {
        output: tokio::sync::mpsc::UnboundedReceiver<Output>,
        writes: Arc<Mutex<Vec<u8>>>,
    }

    impl Producer for Probe {
        async fn write(&mut self, bytes: Vec<u8>) -> Result<(), ProducerError> {
            self.writes.lock().unwrap().extend(bytes);
            Ok(())
        }
        async fn resize(&mut self, _: ScreenSize) -> Result<(), ProducerError> {
            Ok(())
        }
        async fn next_output(&mut self) -> Option<Output> {
            self.output.recv().await
        }
        async fn close(self) {}
    }

    fn probe() -> (TerminalSession, tokio::sync::mpsc::UnboundedSender<Output>, Arc<Mutex<Vec<u8>>>)
    {
        let (sender, output) = tokio::sync::mpsc::unbounded_channel();
        let writes = Arc::new(Mutex::new(Vec::new()));
        let session = TerminalSession::start(
            Probe { output, writes: Arc::clone(&writes) },
            ScreenSize::new(20, 4),
            Options::default(),
        );
        (session, sender, writes)
    }

    async fn printed(
        session: &TerminalSession,
        sender: &tokio::sync::mpsc::UnboundedSender<Output>,
        bytes: &[u8],
    ) {
        let before = session.shared.generation.load(Ordering::Relaxed);
        sender.send(Output::Bytes(bytes.to_vec())).unwrap();
        tokio::time::timeout(Duration::from_secs(2), async {
            while session.shared.generation.load(Ordering::Relaxed) == before {
                session.changed().await;
            }
        })
        .await
        .expect("the pump fed the bytes");
    }

    async fn received(writes: &Mutex<Vec<u8>>, expected: &[u8]) {
        tokio::time::timeout(Duration::from_secs(2), async {
            while writes.lock().unwrap().as_slice() != expected {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap_or_else(|_| panic!("sent {:?}, wanted {:?}", writes.lock().unwrap(), expected));
    }

    /// The parser holding the terminal — a long feed during a `cat` — does
    /// not hold up typing, and the keys still go out in order, encoded
    /// against the modes the program set.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn typing_does_not_wait_for_the_parser() {
        let (session, sender, writes) = probe();
        // Application cursor keys, then enough lines to scroll back over.
        printed(&session, &sender, b"\x1b[?1h1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8").await;
        session.scroll(Scroll::PageUp);
        assert!(session.viewport().offset > 0, "scrolled back before typing");

        let busy = session.shared.terminal.lock().unwrap();
        let (done, finished) = std::sync::mpsc::channel();
        let sent = std::thread::scope(|scope| {
            scope.spawn(|| {
                session.send(&Input::character('a')).unwrap();
                session.send(&Input::key(Key::Up)).unwrap();
                session.send(&Input::character('b')).unwrap();
                done.send(()).unwrap();
            });
            let sent = finished.recv_timeout(Duration::from_secs(1));
            // Released before asserting, so a regression fails rather than
            // deadlocking the scope.
            drop(busy);
            sent
        });
        assert!(sent.is_ok(), "send waited for the terminal lock");

        received(&writes, b"a\x1bOAb").await;
        assert_eq!(session.viewport().offset, 0, "typing returned to the live screen");
    }

    /// A copy request is delivered once, without the terminal lock.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_copy_is_taken_once_without_the_terminal() {
        let (session, sender, _) = probe();
        assert_eq!(session.take_clipboard(), None);
        printed(&session, &sender, b"\x1b]52;c;aGVsbG8=\x07").await;

        let busy = session.shared.terminal.lock().unwrap();
        let (done, finished) = std::sync::mpsc::channel();
        let taken = std::thread::scope(|scope| {
            scope.spawn(|| done.send(session.take_clipboard()).unwrap());
            let taken = finished.recv_timeout(Duration::from_secs(1));
            drop(busy);
            taken
        });
        assert_eq!(
            taken.expect("take_clipboard waited for the terminal lock"),
            Some("hello".to_owned())
        );
        assert_eq!(session.take_clipboard(), None);
    }
}
