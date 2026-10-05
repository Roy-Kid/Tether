//! Getting from "a shell on this machine" to a running session.
//!
//! The local counterpart to [`Dial`], and deliberately the same shape: a
//! builder for the parts that vary, one call that hands back a
//! [`TerminalSession`]. What comes back is the *same type* a remote dial
//! returns, because a session is a byte stream bound to a terminal and
//! neither half cares which side of a network the bytes came from (spec §8).
//!
//! What is missing here is the point of it. There is no endpoint, no
//! verifier and no credential, because there is no handshake: the whole of
//! [`Dial`]'s ceremony exists to establish trust with a stranger, and this
//! machine is not one.
//!
//! [`Dial`]: crate::Dial

use tether_local::{Command, LocalError, Shell, WindowSize};
use tether_terminal::{Options, ScreenSize};

use crate::session::TerminalSession;

/// What to run on this machine, and what it should believe it is running on.
#[derive(Debug, Clone)]
pub struct Local {
    command: Command,
    size: ScreenSize,
    options: Options,
    history: Option<crate::history::HistoryArchive>,
}

impl Local {
    /// A session on the person's login shell.
    ///
    /// The default is the interesting one: a terminal application that opens
    /// "a local terminal" means this, and making a consumer assemble it would
    /// be handing back the ceremony this crate exists to have written once
    /// (spec §16).
    pub fn new() -> Self {
        Self::running(Command::login_shell())
    }

    /// A session on something other than the login shell.
    pub fn running(command: Command) -> Self {
        Self { command, size: ScreenSize::new(80, 24), options: Options::default(), history: None }
    }

    /// Where the shell starts. The person's home directory when unset.
    pub fn directory(mut self, directory: impl Into<std::path::PathBuf>) -> Self {
        self.command = self.command.directory(directory);
        self
    }

    /// What the shell will see in `$TERM`.
    pub fn term(mut self, term: impl Into<String>) -> Self {
        self.command = self.command.term(term);
        self
    }

    pub fn size(mut self, size: ScreenSize) -> Self {
        self.size = size;
        self
    }

    pub fn history(mut self, history: Option<crate::history::HistoryArchive>) -> Self {
        self.history = history;
        self
    }

    pub fn options(mut self, options: Options) -> Self {
        self.options = options;
        self
    }

    /// Opens a pseudo-terminal, starts the shell, and begins pumping it.
    ///
    /// `async` although nothing here waits on anything: the session it
    /// returns spawns its pump task, and a synchronous call would panic for
    /// a caller who was not already inside a runtime. A signature that can
    /// only be used correctly is better than a comment asking for it.
    pub async fn open(self) -> Result<TerminalSession, LocalError> {
        let shell = Shell::open(self.command, WindowSize::new(self.size.columns, self.size.rows))?;
        // Local, not absent. Nothing was authenticated and nothing is being
        // held open — but a second command can be run here just as it can on
        // the far side of a network, and saying so is what keeps a feature
        // built on that from being remote-only by accident.
        let terminal_name = shell.tty_name().map(str::to_owned);
        let process_id = shell.process_id();
        Ok(TerminalSession::start_with(
            shell,
            self.size,
            self.options,
            crate::Connection::Local,
            terminal_name,
            process_id,
            self.history,
        ))
    }
}

impl Default for Local {
    fn default() -> Self {
        Self::new()
    }
}
