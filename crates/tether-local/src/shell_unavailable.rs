//! iOS has no pseudo-terminal. The type still exists so a session can be
//! asked for a local shell and be refused, without linking `portable-pty`.

use crate::command::Command;
use crate::error::LocalError;

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

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Output {
    Bytes(Vec<u8>),
    Exited(u32),
}

pub(crate) const FOREIGN_TERMINAL_CLAIMS: [&str; 5] =
    ["TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "TMUX", "TMUX_PANE"];

pub fn process_current_directory(_pid: u32) -> Option<String> {
    None
}

/// A shell this platform will not start.
#[derive(Debug)]
pub struct Shell {
    size: WindowSize,
}

impl Shell {
    pub fn open(_command: Command, _size: WindowSize) -> Result<Self, LocalError> {
        Err(LocalError::Unsupported)
    }

    pub fn size(&self) -> WindowSize {
        self.size
    }

    pub fn tty_name(&self) -> Option<&str> {
        None
    }

    pub fn process_id(&self) -> Option<u32> {
        None
    }

    pub fn current_directory(&self) -> Option<String> {
        None
    }

    pub async fn write(&mut self, _bytes: impl Into<Vec<u8>>) -> Result<(), LocalError> {
        Err(LocalError::Unsupported)
    }

    pub fn resize(&mut self, _size: WindowSize) -> Result<(), LocalError> {
        Err(LocalError::Unsupported)
    }

    pub async fn next_output(&mut self) -> Option<Output> {
        None
    }

    pub fn close(self) {}
}
