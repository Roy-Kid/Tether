//! Attaching through an OpenSSH client, without a real network.
//!
//! ControlMaster is OpenSSH's own socket. The composition here is "run ssh
//! the way a person would", so a fake binary that answers `ssh -O check`
//! and runs a command is enough to prove the argv and the lease. A live
//! cluster is what the app is for.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use tether_core::terminal::{Options, ScreenSize};
use tether_core::{Connection, SshClient, TerminalSession};

fn fake_ssh(check_exit: i32) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "tether-ssh-client-{}-{check_exit}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("time")
            .as_nanos()
    ));
    std::fs::create_dir_all(&dir).expect("a temp directory");
    let path = dir.join("ssh");
    std::fs::write(
        &path,
        format!(
            r#"#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
subsystem = "-s" in args
if "-O" in args:
    sys.stderr.write("Master running (pid=1)\n")
    sys.exit({check_exit})
if "--" in args:
    args = args[args.index("--") + 1:]
else:
    stripped = []
    i = 0
    while i < len(args):
        if args[i] in ("-T", "-tt", "-t"):
            i += 1
        elif args[i] == "-o":
            i += 2
        else:
            stripped.append(args[i])
            i += 1
    args = stripped
if not args:
    sys.exit(2)
args = args[1:]
if subsystem:
    sys.stdout.write("subsystem " + " ".join(args))
    sys.stdout.flush()
    sys.exit(0)
if not args:
    sys.stdout.write("attached\n")
    sys.stdout.flush()
    sys.exit(0)
os.execv("/bin/sh", ["sh", "-c", args[0]])
"#
        ),
    )
    .expect("the fake ssh");
    let mut permissions = std::fs::metadata(&path).expect("metadata").permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&path, permissions).expect("executable");
    path
}

fn client(program: &Path) -> SshClient {
    SshClient::new("Arrhenius").program(program.to_string_lossy().into_owned())
}

#[tokio::test]
async fn a_running_master_is_what_ssh_check_says() {
    assert!(client(&fake_ssh(0)).master_running().await);
    assert!(!client(&fake_ssh(255)).master_running().await, "a refused check is not a master");
}

#[tokio::test]
async fn an_empty_target_is_not_a_master() {
    assert!(!SshClient::new("").master_running().await);
}

/// Not CI. A developer with a live Arrhenius ControlMaster — even one
/// hashed under yesterday's local hostname — should get a command through
/// it without a handshake.
#[tokio::test]
async fn a_live_openssh_master_runs_a_command() {
    let client = SshClient::new("Arrhenius");
    let home = std::env::var("HOME").unwrap_or_default();
    let known = std::path::Path::new(&home)
        .join(".ssh")
        .join("cm-262eb38b5e7150890591c6caa5b44dc96d090b52");
    if known.exists() {
        assert!(
            client.master_running().await,
            "a master hashed under another local hostname must still be found"
        );
    } else if !client.master_running().await {
        return;
    }
    let captured = Connection::OpenSsh(SshClient::new("Arrhenius"))
        .capture("echo mux-ok", 1024)
        .await
        .expect("the master should run a command");
    assert!(captured.text().contains("mux-ok"), "{}", captured.text());

    let listed = Connection::OpenSsh(SshClient::new("Arrhenius"))
        .capture(
            "tmux list-sessions -F '#{session_id}|#{session_attached}|#{session_name}'",
            64 * 1024,
        )
        .await
        .expect("list-sessions should run on the master");
    assert!(
        listed.succeeded() || listed.complaint().contains("no server running"),
        "stderr={} stdout={}",
        listed.complaint(),
        listed.text()
    );
}

#[tokio::test]
async fn a_second_command_runs_on_the_far_side_of_ssh() {
    let program = fake_ssh(0);
    let connection = Connection::OpenSsh(client(&program));
    let captured = connection.capture("printf 'from-mux'", 1024).await.expect("ssh should run");
    assert_eq!(captured.text(), "from-mux");
    assert!(captured.succeeded());
}

/// SFTP through a master is `ssh -s <alias> sftp`: a subsystem the far side's
/// `sshd` resolves, not a command line a shell there would parse.
#[tokio::test]
async fn files_ask_the_far_side_for_its_sftp_subsystem() {
    let program = fake_ssh(0);
    let mut channel = Connection::OpenSsh(client(&program)).sftp().await.expect("ssh should start");
    let said = channel.read().await.expect("a read").expect("some bytes");
    assert_eq!(String::from_utf8_lossy(&said), "subsystem sftp");
    channel.close().await;
}

async fn settle(session: &TerminalSession, what: &str, predicate: impl Fn(&str) -> bool) -> String {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let text = session.screen().text();
        if predicate(&text) {
            return text;
        }
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            panic!("timed out waiting for {what}; the screen held:\n{text}");
        }
        if tokio::time::timeout(remaining, session.changed()).await != Ok(true) {
            let text = session.screen().text();
            if predicate(&text) {
                return text;
            }
            panic!("the session ended while waiting for {what}; the screen held:\n{text}");
        }
    }
}

#[tokio::test]
async fn an_interactive_shell_is_a_session() {
    let program = fake_ssh(0);
    let session = client(&program)
        .connect("xterm-256color", ScreenSize::new(80, 24), Options::default())
        .await
        .expect("ssh should start");

    let screen = settle(&session, "the attach banner", |text| text.contains("attached")).await;
    assert!(screen.contains("attached"), "{screen}");
    assert!(session.connection().is_some(), "the lease must survive the attach");
}
