//! Attaching to an OpenSSH client, usually a ControlMaster.
//!
//! ControlMaster is not an SSH protocol feature. It is OpenSSH's own
//! multiplexing on a Unix socket, and the client that created the socket is
//! the one that knows how to ask it for another session. russh has never
//! heard of it; speaking the mux protocol ourselves would be rewriting the
//! client that already owns it (Decisions/0010).
//!
//! So this is `ssh`, as a producer. The interactive shell is a
//! pseudo-terminal running `ssh -tt`. A second command is `ssh -T` on pipes.
//! Both are [`tether_local`], which still links no SSH symbol.

use std::path::{Path, PathBuf};
use std::time::Duration;

use sha1::{Digest, Sha1};
use tether_local::{Command, Shell, WindowSize};
use tether_terminal::{Options, ScreenSize};

use crate::connection::{Connection, ConnectionError};
use crate::session::TerminalSession;

/// How long `ssh -O check` is given to answer.
///
/// A live master answers immediately. A hanging DNS lookup is not a master,
/// and waiting for one would freeze the connect path on a name that russh
/// could have dialled.
const CHECK_BUDGET: Duration = Duration::from_secs(2);

/// An OpenSSH client aimed at one config alias.
///
/// The alias is the stanza name (`Arrhenius`), not the resolved hostname,
/// because that is the name `ssh` takes and the name a ControlPath was keyed
/// on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SshClient {
    program: String,
    target: String,
    /// Set when the default ControlPath missed a live master — usually
    /// because `%C` was hashed with a different local hostname than today.
    control_path: Option<String>,
}

impl SshClient {
    pub fn new(target: impl Into<String>) -> Self {
        Self { program: default_ssh(), target: target.into(), control_path: None }
    }

    /// Which binary to exec. Tests inject a fake; production leaves the default.
    pub fn program(mut self, program: impl Into<String>) -> Self {
        self.program = program.into();
        self
    }

    pub fn target(&self) -> &str {
        &self.target
    }

    /// Whether a multiplexing master will accept another session.
    ///
    /// Tries `ssh -O check` first, which is what a person at a prompt would
    /// get. If that misses because `%C` was hashed under another local
    /// hostname, looks for a sibling socket OpenSSH would have used then.
    pub async fn master_running(&self) -> bool {
        if cfg!(target_os = "ios") || self.target.is_empty() {
            return false;
        }
        if self.check(None).await {
            return true;
        }
        self.discover_alternate_socket().await.is_some()
    }

    /// An interactive shell on the far side of this client.
    ///
    /// `-tt` forces a remote pseudo-terminal even if ssh is unsure it has a
    /// local one. `BatchMode` is load-bearing: a master that died between
    /// the check and this call must fail rather than prompt inside the
    /// terminal for a password the person was not asked to give this process.
    /// Picks an explicit ControlPath when the default `%C` missed a live master.
    pub(crate) async fn with_resolved_path(mut self) -> Self {
        if self.control_path.is_none() && !self.check(None).await {
            self.control_path = self.discover_alternate_socket().await;
        }
        self
    }

    pub async fn connect(
        self,
        term: impl Into<String>,
        size: ScreenSize,
        options: Options,
    ) -> Result<TerminalSession, ConnectionError> {
        let this = self.with_resolved_path().await;
        let term = term.into();
        let command = this.ssh_command(true).term(term);
        let shell = Shell::open(command, WindowSize::new(size.columns, size.rows))
            .map_err(ConnectionError::new)?;
        Ok(TerminalSession::start_with(shell, size, options, Connection::OpenSsh(this)))
    }

    pub(crate) fn exec(&self, command: &str) -> Command {
        self.ssh_command(false).arg(command)
    }

    /// `ssh -s <alias> <name>`: a subsystem on the far side, which its
    /// `sshd` resolves to a program without a shell parsing anything.
    pub(crate) fn subsystem(&self, name: &str) -> Command {
        self.options(false).arg("-s").arg("--").arg(&self.target).arg(name)
    }

    fn ssh_command(&self, tty: bool) -> Command {
        self.options(tty).arg("--").arg(&self.target)
    }

    /// Everything before the target: how to reach it, not what to run there.
    fn options(&self, tty: bool) -> Command {
        let mut command = Command::new(&self.program)
            .arg(if tty { "-tt" } else { "-T" })
            .arg("-o")
            .arg("BatchMode=yes")
            // Diagnostics on stdout/stderr would be parsed as tmux metadata
            // or, on an attach stream, as a protocol failure. The mux already
            // authenticated; a warning is not an answer.
            .arg("-o")
            .arg("LogLevel=ERROR");
        if let Some(path) = &self.control_path {
            command = command.arg("-o").arg(format!("ControlPath={path}"));
        }
        command
    }

    async fn check(&self, control_path: Option<&str>) -> bool {
        let mut command =
            Command::new(&self.program).arg("-O").arg("check").arg("-o").arg("ConnectTimeout=2");
        if let Some(path) = control_path {
            command = command.arg("-o").arg(format!("ControlPath={path}"));
        }
        command = command.arg("--").arg(&self.target);
        match tokio::time::timeout(CHECK_BUDGET, command.capture(1024)).await {
            Ok(Ok(captured)) => captured.succeeded(),
            _ => false,
        }
    }

    /// A ControlPath hashed with a local hostname this machine no longer
    /// uses. `%C` is SHA1 of `%l%h%p%r`; a laptop that picked up a new
    /// FQDN looks for a different socket than the master that is still
    /// running from this morning.
    async fn discover_alternate_socket(&self) -> Option<String> {
        let config = self.ssh_g().await?;
        let current = PathBuf::from(&config.control_path);
        let dir = current.parent()?;
        let name = current.file_name().and_then(|n| n.to_str())?;

        for local in local_host_names() {
            let hashed = percent_c(&local, &config.host, config.port, &config.user);
            let Some(candidate_name) = replace_hash(name, &hashed) else {
                continue;
            };
            let candidate = dir.join(candidate_name);
            if candidate == current {
                continue;
            }
            if !is_socket(&candidate) {
                continue;
            }
            let path = candidate.to_string_lossy().into_owned();
            if self.check(Some(&path)).await {
                return Some(path);
            }
        }
        self.scan_control_dir(&current, name).await
    }

    /// Every live socket next to the expected ControlPath. Hostname hashing
    /// misses names this process cannot see (`scutil` absent from a GUI
    /// PATH); `ssh -O check` on the socket itself is the authority.
    async fn scan_control_dir(&self, current: &Path, name: &str) -> Option<String> {
        let dir = current.parent()?;
        let prefix = control_prefix(name);
        let entries = std::fs::read_dir(dir).ok()?;
        let mut tried = 0;
        for entry in entries {
            if tried >= 16 {
                break;
            }
            let Ok(entry) = entry else { continue };
            let path = entry.path();
            if path == *current {
                continue;
            }
            let Some(file_name) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            if !file_name.starts_with(prefix) {
                continue;
            }
            if !is_socket(&path) {
                continue;
            }
            tried += 1;
            let path = path.to_string_lossy().into_owned();
            if self.check(Some(&path)).await {
                return Some(path);
            }
        }
        None
    }

    async fn ssh_g(&self) -> Option<SshG> {
        let command = Command::new(&self.program).arg("-G").arg("--").arg(&self.target);
        let captured =
            tokio::time::timeout(CHECK_BUDGET, command.capture(8 * 1024)).await.ok()?.ok()?;
        SshG::parse(&String::from_utf8_lossy(&captured.stdout))
    }
}

struct SshG {
    host: String,
    port: u16,
    user: String,
    control_path: String,
}

impl SshG {
    fn parse(text: &str) -> Option<Self> {
        let mut host = None;
        let mut port = None;
        let mut user = None;
        let mut control_path = None;
        for line in text.lines() {
            let Some((key, value)) = line.split_once(' ') else { continue };
            match key {
                "hostname" => host = Some(value.to_owned()),
                "port" => port = value.parse().ok(),
                "user" => user = Some(value.to_owned()),
                "controlpath" => control_path = Some(value.to_owned()),
                _ => {}
            }
        }
        Some(Self { host: host?, port: port?, user: user?, control_path: control_path? })
    }
}

/// SHA1 of `%l%h%p%r`, which is OpenSSH's `%C`.
fn percent_c(local: &str, host: &str, port: u16, user: &str) -> String {
    let mut hasher = Sha1::new();
    hasher.update(local.as_bytes());
    hasher.update(host.as_bytes());
    hasher.update(port.to_string().as_bytes());
    hasher.update(user.as_bytes());
    hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Replaces a 40-character hex run in the filename with another `%C`.
///
/// ControlPath is `~/.ssh/cm-%C` for the people this exists for. Anything
/// without a hash in it is not a `%C` path, and guessing would attach to
/// the wrong master.
fn replace_hash(name: &str, hashed: &str) -> Option<String> {
    let bytes = name.as_bytes();
    if bytes.len() < 40 {
        return None;
    }
    let start =
        (0..=bytes.len() - 40).find(|&i| bytes[i..i + 40].iter().all(|b| b.is_ascii_hexdigit()))?;
    let mut replaced = name.to_owned();
    replaced.replace_range(start..start + 40, hashed);
    Some(replaced)
}

/// The filename up to a `%C` hash, e.g. `cm-` from `cm-<40 hex>`.
fn control_prefix(name: &str) -> &str {
    let bytes = name.as_bytes();
    if bytes.len() < 40 {
        return name;
    }
    match (0..=bytes.len() - 40).find(|&i| bytes[i..i + 40].iter().all(|b| b.is_ascii_hexdigit())) {
        Some(0) => "",
        Some(start) => &name[..start],
        None => name,
    }
}

fn is_socket(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::FileTypeExt;
        std::fs::metadata(path).map(|m| m.file_type().is_socket()).unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        false
    }
}

fn local_host_names() -> Vec<String> {
    let mut names = Vec::new();
    fn push(names: &mut Vec<String>, value: String) {
        let value = value.trim().to_owned();
        if !value.is_empty() && !names.contains(&value) {
            names.push(value);
        }
    }
    fn run(names: &mut Vec<String>, program: &str, args: &[&str]) {
        let mut command = std::process::Command::new(program);
        command.args(args);
        if let Ok(output) = command.output()
            && output.status.success()
        {
            push(names, String::from_utf8_lossy(&output.stdout).into_owned());
        }
    }

    // Absolute paths: a GUI application often has a PATH that does not
    // include `/usr/sbin`, and a missing `scutil` is how `%C` hashed under
    // yesterday's local name is never tried.
    run(&mut names, "/bin/hostname", &[]);
    run(&mut names, "/bin/hostname", &["-s"]);
    run(&mut names, "/bin/hostname", &["-f"]);

    if cfg!(target_os = "macos") {
        for key in ["LocalHostName", "ComputerName", "HostName"] {
            run(&mut names, "/usr/sbin/scutil", &["--get", key]);
        }
    }

    let extras: Vec<String> = names
        .iter()
        .filter_map(|name| name.split('.').next().map(|short| format!("{short}.local")))
        .collect();
    for extra in extras {
        push(&mut names, extra);
    }
    names
}

fn default_ssh() -> String {
    if cfg!(target_os = "macos") && std::path::Path::new("/usr/bin/ssh").exists() {
        "/usr/bin/ssh".to_owned()
    } else {
        "ssh".to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percent_c_matches_openssh() {
        assert_eq!(
            percent_c("RoydeMacBook-Air.local", "login.hpc.arrhenius.naiss.se", 22, "jicli594"),
            "262eb38b5e7150890591c6caa5b44dc96d090b52"
        );
    }

    #[test]
    fn a_hash_in_the_filename_is_replaced() {
        let name = "cm-0093acfd828fe3b9300414f1e65cfe23aba737bb";
        let hashed = "262eb38b5e7150890591c6caa5b44dc96d090b52";
        assert_eq!(
            replace_hash(name, hashed).as_deref(),
            Some("cm-262eb38b5e7150890591c6caa5b44dc96d090b52")
        );
        assert_eq!(replace_hash("mux-%r@%h:%p", hashed), None);
    }

    #[test]
    fn control_prefix_stops_at_the_hash() {
        assert_eq!(control_prefix("cm-0093acfd828fe3b9300414f1e65cfe23aba737bb"), "cm-");
        assert_eq!(control_prefix("mux-%r@%h:%p"), "mux-%r@%h:%p");
    }
}
