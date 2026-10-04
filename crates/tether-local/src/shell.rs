//! A live shell on this machine.

use std::io::{Read, Write};
use std::sync::{Arc, Mutex};

use portable_pty::{ChildKiller, CommandBuilder, MasterPty, PtySize, native_pty_system};

use crate::command::Command;
use crate::error::LocalError;

/// How big the shell believes its terminal is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WindowSize {
    pub columns: u16,
    pub rows: u16,
}

impl WindowSize {
    pub fn new(columns: u16, rows: u16) -> Self {
        Self { columns, rows }
    }
}

impl Default for WindowSize {
    fn default() -> Self {
        Self { columns: 80, rows: 24 }
    }
}

/// Something the shell produced.
///
/// Bytes, not text: a shell emits whatever it likes, including invalid UTF-8
/// mid-sequence, and deciding what that means belongs to the terminal — this
/// crate never interprets the stream (spec §8).
///
/// There is no stderr arm, and that is not an omission. A pseudo-terminal
/// gives the child one stream by construction: a program's stderr is already
/// interleaved with its stdout by the kernel, in the order it was written.
/// Separating them here would mean inventing an order that never existed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Output {
    Bytes(Vec<u8>),
    /// The program ended with this status. More output may still arrive
    /// after it, which is why it is an event rather than the end.
    Exited(u32),
}

/// How much output may sit between the shell and the terminal engine.
///
/// Bounded on purpose. `yes` fills a pipe faster than any terminal can parse
/// it, and an unbounded queue would answer that by growing until the process
/// died. A full channel instead stops the reader thread, which stops draining
/// the pseudo-terminal, which blocks the writer inside the kernel — the same
/// backpressure a real terminal applies, arrived at by doing nothing.
const BACKLOG: usize = 64;

/// What one read from the pseudo-terminal may return.
const CHUNK: usize = 8 * 1024;

/// How long a shell is given to stop arguing about the window size.
///
/// Generous on purpose: it costs a handful of `ioctl`s once per session, and
/// the failure it prevents is permanent for the life of the terminal.
const SETTLING: std::time::Duration = std::time::Duration::from_millis(1500);

/// How often the size is checked while the shell settles.
const SETTLING_INTERVAL: std::time::Duration = std::time::Duration::from_millis(25);

/// Claims about *which terminal this is*, which the child must not inherit.
///
/// The child inherits this process's environment, and this process was
/// started by something — a shell, a launcher, an IDE — that may have set
/// these. They then describe a terminal the child is not running in, and
/// shells act on them: with `TERM_PROGRAM=Apple_Terminal`, zsh sources
/// `/etc/zshrc_Apple_Terminal` and replays a saved Terminal.app session, so
/// the first thing a person sees is somebody else's old output. Measured, not
/// imagined — it was the first thing on screen the first time this ran.
/// `TMUX` and `TMUX_PANE` are the same kind of claim: if Tether was launched
/// from tmux, its shell and local tmux commands must not attach to the
/// launcher's client or refuse a nested attach.
///
/// Removed rather than corrected, because there is no honest value to write.
/// A component may not name its consumer, so it cannot answer "which terminal
/// is this?"; a consumer that wants to advertise itself can set these on the
/// far side, having earned the claim. `TERM` is different and is set: it
/// describes what can be *drawn*, which is a question this crate can answer.
pub(crate) const FOREIGN_TERMINAL_CLAIMS: [&str; 5] =
    ["TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "TMUX", "TMUX_PANE"];

/// Read the working directory of a live local shell process.
#[cfg(target_os = "macos")]
pub fn process_current_directory(pid: u32) -> Option<String> {
    use std::ffi::CStr;

    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let size = unsafe {
        libc::proc_pidinfo(
            pid as libc::pid_t,
            libc::PROC_PIDVNODEPATHINFO,
            0,
            (&mut info as *mut libc::proc_vnodepathinfo).cast(),
            std::mem::size_of::<libc::proc_vnodepathinfo>() as libc::c_int,
        )
    };
    if size != std::mem::size_of::<libc::proc_vnodepathinfo>() as libc::c_int {
        return None;
    }
    let path = unsafe { CStr::from_ptr(info.pvi_cdir.vip_path.as_ptr().cast()) };
    let path = path.to_str().ok()?;
    path.starts_with('/').then(|| path.to_owned())
}

#[cfg(all(unix, not(target_os = "macos")))]
pub fn process_current_directory(pid: u32) -> Option<String> {
    let path = std::fs::read_link(format!("/proc/{pid}/cwd")).ok()?;
    let path = path.to_str()?;
    path.starts_with('/').then(|| path.to_owned())
}

#[cfg(not(unix))]
pub fn process_current_directory(_pid: u32) -> Option<String> {
    None
}

/// A shell running on a pseudo-terminal of its own.
///
/// Dropping it hangs the shell up, exactly as closing a terminal window does.
pub struct Shell {
    /// Held for its lifetime: this is the handle `resize` speaks through, and
    /// dropping it early would close the fd the shell is attached to.
    ///
    /// Shared, because [`hold_size`] speaks through it too — and `Weak`, on
    /// that side, so a settling thread cannot keep a closed terminal alive.
    master: Arc<Mutex<Box<dyn MasterPty + Send>>>,
    /// The controlling tty path, when the platform exposes it.
    tty_name: Option<String>,
    /// PID of the shell process group leader, for reading its live cwd.
    process_id: Option<u32>,
    /// The size this terminal is supposed to be, for [`hold_size`] to defend.
    wanted: Arc<Mutex<PtySize>>,
    /// Behind a lock because a write happens on a blocking thread, and
    /// `&mut self` on [`Self::write`] is what keeps two of them from ever
    /// being in flight at once.
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    killer: Box<dyn ChildKiller + Send + Sync>,
    output: tokio::sync::mpsc::Receiver<Vec<u8>>,
    exit: tokio::sync::oneshot::Receiver<u32>,
    /// Remembered as soon as the child is reaped, delivered only once the
    /// output has drained.
    status: Option<u32>,
    drained: bool,
    finished: bool,
    size: WindowSize,
}

impl Shell {
    /// Starts `command` on a new pseudo-terminal.
    ///
    /// Synchronous, because none of it waits on anything: opening the pair
    /// and forking are two system calls. What comes *out* is asynchronous,
    /// and that is [`Self::next_output`].
    pub fn open(command: Command, size: WindowSize) -> Result<Self, LocalError> {
        // iOS forbids an application from starting another process at all.
        // Checked before anything is opened, so the failure is the true one
        // rather than whichever system call happens to be refused first.
        if cfg!(target_os = "ios") {
            return Err(LocalError::Unsupported);
        }

        let (program, arguments, directory, term) = command.parts();

        let pair = native_pty_system()
            .openpty(pty_size(size))
            .map_err(|error| LocalError::NoTerminal { cause: error.to_string() })?;
        let tty_name = pair.master.tty_name().map(|path| path.to_string_lossy().into_owned());

        let mut builder = CommandBuilder::new(program);
        for argument in arguments {
            builder.arg(argument);
        }
        if let Some(directory) = directory {
            builder.cwd(directory);
        }
        // Set rather than inherited: the terminal the shell is talking to is
        // the one this process draws, not the one that happened to launch it.
        // An inherited `TERM` from a build system is how a shell ends up
        // emitting sequences nothing here can render.
        builder.env("TERM", term);
        for claim in FOREIGN_TERMINAL_CLAIMS {
            builder.env_remove(claim);
        }

        let mut child = pair.slave.spawn_command(builder).map_err(|error| {
            LocalError::NotStarted { program: program.to_owned(), cause: error.to_string() }
        })?;
        // Before spawning, the PTY has no foreground process group. Keep the
        // actual child PID so cwd follows the shell even while a job is in front.
        let process_id = child.process_id();

        // The slave must go now. While this process still holds one, the
        // kernel sees a reader on the terminal and the master never reports
        // end-of-file — so a shell that exited would leave the session
        // waiting for output that can no longer come.
        drop(pair.slave);

        let reader = pair
            .master
            .try_clone_reader()
            .map_err(|error| LocalError::NoTerminal { cause: error.to_string() })?;
        let writer = pair
            .master
            .take_writer()
            .map_err(|error| LocalError::NoTerminal { cause: error.to_string() })?;
        let killer = child.clone_killer();

        let (bytes, output) = tokio::sync::mpsc::channel(BACKLOG);
        // Dedicated threads rather than `spawn_blocking`: both of these block
        // for as long as the shell lives, and tokio's blocking pool is sized
        // for work that finishes. Parking two of its threads per terminal tab
        // would starve every other blocking caller in the process, and its
        // shutdown waits for them.
        std::thread::Builder::new()
            .name("tether-local reader".to_owned())
            .spawn(move || pump_output(reader, bytes))
            .map_err(|error| LocalError::NoTerminal { cause: error.to_string() })?;

        let (reaped, exit) = tokio::sync::oneshot::channel();
        std::thread::Builder::new()
            .name("tether-local reaper".to_owned())
            .spawn(move || {
                // A child nobody waits for is a zombie for the life of the
                // process. The status is the useful part; the reaping is the
                // necessary part, and it happens either way.
                let status = child.wait().map(|status| status.exit_code()).unwrap_or_default();
                let _ = reaped.send(status);
            })
            .map_err(|error| LocalError::NoTerminal { cause: error.to_string() })?;

        let wanted = Arc::new(Mutex::new(pty_size(size)));
        let master = Arc::new(Mutex::new(pair.master));

        // A shell writes its own idea of the size back while it is starting.
        // Holding the requested size across that window is the difference
        // between a terminal that is the size it was asked to be and one that
        // is 80x24 for ever — see `hold_size`.
        std::thread::Builder::new()
            .name("tether-local size".to_owned())
            .spawn({
                let master = Arc::downgrade(&master);
                let wanted = Arc::clone(&wanted);
                move || hold_size(&master, &wanted)
            })
            .map_err(|error| LocalError::NoTerminal { cause: error.to_string() })?;

        Ok(Self {
            master,
            tty_name,
            process_id,
            wanted,
            writer: Arc::new(Mutex::new(writer)),
            killer,
            output,
            exit,
            status: None,
            drained: false,
            finished: false,
            size,
        })
    }

    /// The size last requested.
    pub fn size(&self) -> WindowSize {
        self.size
    }

    /// The path of this shell's controlling tty, when available.
    pub fn tty_name(&self) -> Option<&str> {
        self.tty_name.as_deref()
    }

    /// The process group leader, when this PTY backend exposes it.
    pub fn process_id(&self) -> Option<u32> {
        self.process_id
    }

    /// The shell process's current directory, even when it does not emit OSC 7.
    pub fn current_directory(&self) -> Option<String> {
        self.process_id.and_then(process_current_directory)
    }

    /// Sends bytes to the shell's input.
    ///
    /// On a blocking thread because it genuinely can block: a pseudo-terminal
    /// holds about a kilobyte of input, so a paste larger than that waits for
    /// the shell to read. Doing that on the caller's thread would stall an
    /// async runtime on a person pressing ⌘V.
    ///
    /// `&mut self` rather than `&self`, so the compiler — not a convention —
    /// guarantees that two writes are never in flight and cannot arrive out
    /// of order.
    pub async fn write(&mut self, bytes: impl Into<Vec<u8>>) -> Result<(), LocalError> {
        let bytes = bytes.into();
        if bytes.is_empty() {
            return Ok(());
        }
        let writer = Arc::clone(&self.writer);
        tokio::task::spawn_blocking(move || {
            let mut writer = writer.lock().map_err(|_| LocalError::Ended)?;
            writer
                .write_all(&bytes)
                .map_err(|error| LocalError::Write { cause: error.to_string() })?;
            writer.flush().map_err(|error| LocalError::Write { cause: error.to_string() })
        })
        .await
        .map_err(|error| LocalError::Write { cause: error.to_string() })?
    }

    /// Tells the kernel the terminal changed size, which signals the shell.
    ///
    /// An `ioctl`, so it does not block and needs no thread. The signal is
    /// the point: full-screen programs redraw because of `SIGWINCH`, not
    /// because anything was written to them.
    ///
    /// Applying it is not the end of it: a shell started moments ago may
    /// write its own cached size back over this one, so the request is also
    /// recorded for [`hold_size`] to defend. Both halves are needed — this
    /// one makes the change now, that one makes it stick.
    pub fn resize(&mut self, size: WindowSize) -> Result<(), LocalError> {
        let wanted = pty_size(size);

        // The terminal first, then the size — the order [`hold_size`] takes
        // them in as well. Two locks taken in the same order everywhere
        // cannot deadlock; two locks taken in opposite orders eventually
        // will, on a thread nobody was looking at.
        let master = self.master.lock().map_err(|_| LocalError::Ended)?;

        // Recorded before it is applied, so the settling thread defends the
        // new size rather than the one it was started with.
        *self.wanted.lock().map_err(|_| LocalError::Ended)? = wanted;

        master.resize(wanted).map_err(|error| LocalError::Resize { cause: error.to_string() })?;
        drop(master);

        self.size = size;
        Ok(())
    }

    /// The next thing the shell produced, or `None` once it is over.
    ///
    /// An async sequence rather than a callback (spec §13), and cancel-safe:
    /// both halves park on channels that keep what they hold, so abandoning
    /// this future loses nothing.
    pub async fn next_output(&mut self) -> Option<Output> {
        loop {
            if self.finished {
                return None;
            }

            if self.drained {
                // Everything the shell wrote has been handed over. Only now
                // is the status worth reporting: announcing it earlier would
                // invite a consumer to stop reading, and a program's last
                // line arrives after it has exited.
                self.finished = true;
                let status = match self.status.take() {
                    Some(status) => Some(status),
                    None => (&mut self.exit).await.ok(),
                };
                return status.map(Output::Exited);
            }

            tokio::select! {
                // Output first. A shell that exits the instant it starts —
                // `sh -c 'echo hi'` — resolves both arms at once, and an
                // unbiased select would sometimes drop `hi`.
                biased;

                chunk = self.output.recv() => match chunk {
                    Some(bytes) => return Some(Output::Bytes(bytes)),
                    None => self.drained = true,
                },

                reaped = &mut self.exit, if self.status.is_none() => {
                    // Remembered, not returned: the terminal is still being
                    // drained, and the loop comes back for the rest.
                    self.status = reaped.ok();
                    // A closed channel with nothing in it means the reaper
                    // could not report one. Nothing more will arrive on this
                    // arm, and the guard above stops it being polled again.
                    if self.status.is_none() {
                        self.drained = self.output.is_closed() && self.output.is_empty();
                    }
                }
            }
        }
    }

    /// Hangs the shell up, the way closing a terminal window does.
    ///
    /// `SIGHUP` rather than `SIGKILL`: it reaches the whole session, so a
    /// program running *inside* the shell is told to end too, and a shell
    /// that wants to save its history gets the chance. The reaper thread
    /// collects what follows, so this returns without waiting.
    pub fn close(mut self) {
        let _ = self.killer.kill();
    }
}

impl Drop for Shell {
    fn drop(&mut self) {
        // A dropped handle must not leave a shell running with nothing
        // attached to it. Idempotent: a `close` that already signalled leaves
        // a process that is gone, and `kill` on it simply fails.
        let _ = self.killer.kill();
    }
}

impl std::fmt::Debug for Shell {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Shell").field("size", &self.size).field("finished", &self.finished).finish()
    }
}

/// Keeps the terminal the size it was asked to be while the shell starts.
///
/// A terminal emulator owns its size; the program inside it does not get a
/// vote. `bash` disagrees: it reads the size when it starts, caches it, and
/// writes that copy back with `TIOCSWINSZ` at its first prompt. A resize
/// issued in that window is applied — the kernel confirms it — and then
/// quietly undone a few milliseconds later.
///
/// Measured, because it is invisible otherwise: about one resize in ten was
/// lost, permanently, for the life of that terminal. It is not a rare case in
/// practice, because a tab is opened and *then* laid out, which is a resize
/// arriving a few milliseconds after the shell started. The symptom is a
/// terminal stuck at 80x24 inside a wider pane, with nothing in any log.
///
/// Re-asserting rather than retrying-on-failure, because the write that
/// undoes it lands *after* the one that worked: there is nothing to detect at
/// the time, only something to correct afterwards. It stops as soon as the
/// shell does, and altogether when the terminal is dropped.
fn hold_size(master: &std::sync::Weak<Mutex<Box<dyn MasterPty + Send>>>, wanted: &Mutex<PtySize>) {
    let until = std::time::Instant::now() + SETTLING;

    while std::time::Instant::now() < until {
        std::thread::sleep(SETTLING_INTERVAL);

        // Gone means the terminal was closed, which is the end of this.
        let Some(master) = master.upgrade() else { return };
        let (Ok(master), Ok(wanted)) = (master.lock(), wanted.lock()) else { return };

        match master.get_size() {
            Ok(seen) if seen.rows == wanted.rows && seen.cols == wanted.cols => continue,
            // Something else set the size. Nothing else is entitled to: the
            // frontend is the only thing that knows how big its window is.
            Ok(_) => {
                let _ = master.resize(*wanted);
            }
            // A terminal that cannot be asked its size cannot be defended,
            // and it is about to stop existing anyway.
            Err(_) => return,
        }
    }
}

fn pty_size(size: WindowSize) -> PtySize {
    PtySize {
        rows: size.rows,
        cols: size.columns,
        // The kernel keeps these and passes them on; nothing on this path
        // reads them, and reporting a guess would be worse than reporting
        // nothing.
        pixel_width: 0,
        pixel_height: 0,
    }
}

/// Reads the pseudo-terminal until it ends, on a thread of its own.
fn pump_output(mut reader: Box<dyn Read + Send>, bytes: tokio::sync::mpsc::Sender<Vec<u8>>) {
    let mut buffer = vec![0u8; CHUNK];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => return,
            Ok(read) => {
                // Blocking on purpose: a full channel is how backpressure
                // reaches the shell. A receiver that has gone away means the
                // session was dropped, and there is nobody left to read for.
                if bytes.blocking_send(buffer[..read].to_vec()).is_err() {
                    return;
                }
            }
            // The last process on the far side closed the terminal. Every
            // platform reports it differently — end-of-file on some, `EIO`
            // on others — and none of them is an error worth surfacing.
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return,
        }
    }
}
