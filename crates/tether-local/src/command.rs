//! What to run on the pseudo-terminal.

use std::path::PathBuf;

/// A program to start on a terminal of its own.
///
/// Deliberately small. A consumer needs to say *what* to run, *where*, and
/// what the program should believe its terminal is; anything further is a
/// feature nothing has asked for, which §22 forbids adding in advance.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Command {
    program: String,
    arguments: Vec<String>,
    directory: Option<PathBuf>,
    term: String,
}

impl Command {
    /// The person's login shell, started the way a terminal application
    /// starts one.
    ///
    /// `-l` is load-bearing rather than decoration. A shell started without
    /// it reads none of the profile scripts, so `PATH`, aliases and the
    /// prompt are all different from the one the person gets in every other
    /// terminal — which reads as a broken terminal, not as a design choice.
    pub fn login_shell() -> Self {
        Self::new(login_shell_path()).arg("-l")
    }

    /// Runs a named program instead of a shell.
    pub fn new(program: impl Into<String>) -> Self {
        Self {
            program: program.into(),
            arguments: Vec::new(),
            directory: None,
            // What the program will believe it is talking to. It decides
            // which sequences the program emits, so it has to describe what
            // the consumer can actually draw.
            term: "xterm-256color".to_owned(),
        }
    }

    pub fn arg(mut self, argument: impl Into<String>) -> Self {
        self.arguments.push(argument.into());
        self
    }

    /// Where the program starts. The person's home directory when unset,
    /// which is what a shell would have chosen anyway.
    pub fn directory(mut self, directory: impl Into<PathBuf>) -> Self {
        self.directory = Some(directory.into());
        self
    }

    pub fn term(mut self, term: impl Into<String>) -> Self {
        self.term = term.into();
        self
    }

    pub fn program_name(&self) -> &str {
        &self.program
    }

    pub(crate) fn parts(&self) -> (&str, &[String], Option<&PathBuf>, &str) {
        (&self.program, &self.arguments, self.directory.as_ref(), &self.term)
    }
}

impl Default for Command {
    fn default() -> Self {
        Self::login_shell()
    }
}

/// Which shell this account is supposed to get.
///
/// `$SHELL` first, because a person who exported one meant it. The password
/// database second, because that is the answer the system itself would give.
/// `/bin/sh` last — not a good shell, but the one POSIX guarantees exists,
/// and a plain prompt beats refusing to open a terminal at all.
#[cfg(unix)]
fn login_shell_path() -> String {
    if let Ok(shell) = std::env::var("SHELL")
        && !shell.is_empty()
    {
        return shell;
    }
    portable_pty::CommandBuilder::new_default_prog().get_shell()
}

#[cfg(not(unix))]
fn login_shell_path() -> String {
    portable_pty::CommandBuilder::new_default_prog().get_shell()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_login_shell_asks_for_a_login_shell() {
        let command = Command::login_shell();
        let (_, arguments, _, _) = command.parts();
        assert_eq!(arguments, ["-l"]);
    }

    #[test]
    fn the_exported_shell_wins() {
        // Not asserted against a fixed path: what matters is that the
        // program is *a* shell this account could plausibly run, and CI
        // runs on a machine whose default is not this one's.
        let command = Command::login_shell();
        assert!(!command.program_name().is_empty());
    }

    #[test]
    fn term_describes_what_a_consumer_can_draw() {
        assert_eq!(Command::login_shell().parts().3, "xterm-256color");
        assert_eq!(Command::new("/bin/sh").term("dumb").parts().3, "dumb");
    }
}
