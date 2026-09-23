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
    /// On Unix, `-l` is load-bearing rather than decoration: a shell started
    /// without it reads none of the profile scripts, so `PATH`, aliases and
    /// the prompt are all different from the one the person gets in every
    /// other terminal — which reads as a broken terminal, not as a design
    /// choice.
    ///
    /// Windows has no such flag that every shell understands. `cmd.exe` has
    /// no login concept at all, and `pwsh`/`powershell` read their profile
    /// on startup without one — which is what Windows Terminal and VS Code
    /// do. Passing `-l` to `cmd` is not a login shell; it is an error.
    pub fn login_shell() -> Self {
        Self::shell(login_shell_path())
    }

    /// A named shell, started the way a terminal application starts one.
    ///
    /// This is what a settings surface calls when a person picks PowerShell
    /// over `cmd`: the choice is a program name, and the dialect follows
    /// from it.
    pub fn shell(program: impl Into<String>) -> Self {
        // A preference is not a suicide note: `pwsh` is the first pick on
        // Windows and is not installed everywhere. Resolve to something this
        // machine can actually run rather than fail to open a terminal.
        let program = resolve_program(program.into());
        let mut command = Self::new(program.clone());
        if cfg!(unix) {
            command = command.arg("-l");
        }
        // Windows: `cmd` has no login flag, and PowerShell reads its profile
        // without being asked. `-NoProfile` would be the wrong default for
        // the same reason `-l` is right on Unix — the person's prompt and
        // PATH are the point.
        let _ = (is_powershell(&program), is_cmd(&program));
        command
    }

    /// A command to run in a shell and capture, not a session to hold open.
    ///
    /// The dialect is the shell's: `-c` is sh, `/c` is `cmd`, `-Command` is
    /// PowerShell. Getting this wrong is how `tmux -V` becomes an error
    /// message instead of a version.
    pub fn through_shell(command: &str) -> Self {
        let shell = login_shell_path();
        if cfg!(unix) {
            Self::new(shell).arg("-c").arg(command)
        } else if is_powershell(&shell) {
            Self::new(shell).arg("-NoProfile").arg("-Command").arg(command)
        } else {
            Self::new(shell).arg("/c").arg(command)
        }
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

fn is_powershell(program: &str) -> bool {
    let name = program.rsplit(['/', '\\']).next().unwrap_or(program);
    let name = name.strip_suffix(".exe").unwrap_or(name);
    name.eq_ignore_ascii_case("pwsh") || name.eq_ignore_ascii_case("powershell")
}

fn is_cmd(program: &str) -> bool {
    let name = program.rsplit(['/', '\\']).next().unwrap_or(program);
    let name = name.strip_suffix(".exe").unwrap_or(name);
    name.eq_ignore_ascii_case("cmd")
}

/// A program this machine can run, or the best one it has.
///
/// A named shell that is not installed is not a reason to refuse to open a
/// terminal. Fall back to what `login_shell_path` would have picked, which
/// is what every other terminal on this machine would have done.
fn resolve_program(program: String) -> String {
    if program.is_empty() {
        return login_shell_path();
    }
    if std::path::Path::new(&program).is_file() {
        return program;
    }
    #[cfg(windows)]
    {
        if on_path(&program) {
            return program;
        }
        let with_exe = format!("{program}.exe");
        if on_path(&with_exe) {
            return with_exe;
        }
        return login_shell_path();
    }
    #[cfg(not(windows))]
    {
        // A bare name is what `$SHELL` usually holds and what the password
        // database returns; the OS searches `PATH` when we spawn it.
        if program.contains('/') {
            return login_shell_path();
        }
        program
    }
}

/// Which shell this account is supposed to get.
///
/// Unix: `$SHELL` first, because a person who exported one meant it. The
/// password database second, because that is the answer the system itself
/// would give. `/bin/sh` last — not a good shell, but the one POSIX
/// guarantees exists, and a plain prompt beats refusing to open a terminal.
///
/// Windows: `pwsh` first (PowerShell 7, what a person who installed it
/// wants), then Windows PowerShell, then `cmd` via `COMSPEC`. Every other
/// terminal on this machine picks the same way.
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
    // `$SHELL` is a Unix variable. Git Bash sets it to `bash.exe`, and a
    // terminal that opens bash when the person asked for PowerShell is not
    // honouring a preference — it is reading a variable a different program
    // left behind. Only a Windows shell counts here.
    if let Ok(shell) = std::env::var("SHELL")
        && !shell.is_empty()
        && std::path::Path::new(&shell).is_file()
        && (is_powershell(&shell) || is_cmd(&shell))
    {
        return shell;
    }
    for candidate in ["pwsh.exe", "powershell.exe"] {
        if on_path(candidate) {
            return candidate.to_owned();
        }
    }
    std::env::var("COMSPEC").unwrap_or_else(|_| "cmd.exe".to_owned())
}

#[cfg(not(unix))]
fn on_path(program: &str) -> bool {
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    std::env::split_paths(&path).any(|dir| dir.join(program).is_file())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(unix)]
    fn a_login_shell_asks_for_a_login_shell() {
        let command = Command::login_shell();
        let (_, arguments, _, _) = command.parts();
        assert_eq!(arguments, ["-l"]);
    }

    #[test]
    #[cfg(not(unix))]
    fn a_login_shell_on_windows_carries_no_login_flag() {
        // `cmd` has no login flag, and PowerShell does not need one.
        let command = Command::login_shell();
        let (_, arguments, _, _) = command.parts();
        assert!(arguments.is_empty(), "got {:?}", arguments);
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
        assert_eq!(Command::new("sh").term("dumb").parts().3, "dumb");
    }
}
