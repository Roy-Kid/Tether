use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tether_terminal::Position;
use tether_tmux::{Action, Error, Snapshot, Transport, Workspace};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

struct Process {
    child: tokio::process::Child,
    input: tokio::process::ChildStdin,
    output: tokio::process::ChildStdout,
}
#[async_trait::async_trait]
impl Transport for Process {
    async fn read(&mut self) -> tether_tmux::Result<Option<Vec<u8>>> {
        let mut bytes = vec![0; 8192];
        let n = self.output.read(&mut bytes).await.map_err(|e| Error(e.to_string()))?;
        bytes.truncate(n);
        Ok(if n == 0 { None } else { Some(bytes) })
    }
    async fn write(&mut self, bytes: &[u8]) -> tether_tmux::Result<()> {
        self.input.write_all(bytes).await.map_err(|e| Error(e.to_string()))
    }
    async fn close(&mut self) {
        let _ = self.child.kill().await;
    }
}
struct Server(String);
impl Server {
    fn command(&self, args: &[&str]) -> std::process::Output {
        Command::new("tmux").args(["-L", &self.0]).args(args).output().unwrap()
    }
    fn attach(&self) -> Workspace {
        let mut child = tokio::process::Command::new("tmux")
            .args(["-L", &self.0, "-C", "attach-session", "-t", "test"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        Workspace::start(Process {
            input: child.stdin.take().unwrap(),
            output: child.stdout.take().unwrap(),
            child,
        })
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.command(&["kill-server"]);
    }
}
async fn wait(workspace: &Workspace, condition: impl Fn(&Snapshot) -> bool) -> Snapshot {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let snapshot = workspace.snapshot();
            assert!(snapshot.ended.is_none(), "workspace failed: {:?}", snapshot.ended);
            if condition(&snapshot) {
                return snapshot;
            }
            assert!(workspace.changed().await, "workspace ended before condition");
        }
    })
    .await
    .expect("workspace update timed out")
}

#[tokio::test]
async fn real_tmux_split_input_resize_detach_and_restore() {
    if Command::new("tmux").arg("-V").output().is_err() {
        assert!(std::env::var_os("TETHER_REQUIRE_TMUX").is_none(), "tmux is required");
        eprintln!("tmux unavailable; integration test skipped");
        return;
    }
    let server = Server(format!(
        "tether-test-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    assert!(
        server
            .command(&[
                "-f",
                "/dev/null",
                "new-session",
                "-d",
                "-s",
                "test",
                "-x",
                "100",
                "-y",
                "30",
                "sh"
            ])
            .status
            .success()
    );
    let workspace = server.attach();
    let initial = wait(&workspace, |s| s.panes.len() == 1).await;
    let original = initial.panes[0].info.id;
    workspace.perform(Action::Split(original, true)).await.unwrap();
    let split = wait(&workspace, |s| s.panes.len() == 2).await;
    let other = split.panes.iter().find(|p| p.info.id != original).unwrap().info.id;
    workspace.write(original, b"printf 'TETHER_ORIGINAL\\n'\r".to_vec()).unwrap();
    workspace.write(other, b"printf 'TETHER_SECOND\\n'\r".to_vec()).unwrap();
    wait(&workspace, |s| {
        s.panes.iter().any(|p| p.info.id == original && p.screen.text().contains("TETHER_ORIGINAL"))
            && s.panes
                .iter()
                .any(|p| p.info.id == other && p.screen.text().contains("TETHER_SECOND"))
    })
    .await;
    workspace.perform(Action::Resize(120, 40)).await.unwrap();
    wait(&workspace, |s| s.windows.first().is_some_and(|w| w.width == 120 && w.height == 40)).await;
    // Changes made outside Tether must arrive without polling.
    assert!(server.command(&["rename-window", "-t", "test:0", "External change"]).status.success());
    wait(&workspace, |s| s.windows.first().is_some_and(|w| w.name == "External change")).await;
    workspace.detach();
    tokio::time::timeout(Duration::from_secs(5), async { while workspace.changed().await {} })
        .await
        .unwrap();
    assert!(server.command(&["has-session", "-t", "test"]).status.success());
    let restored = server.attach();
    let snap = wait(&restored, |s| {
        s.panes.len() == 2 && s.panes.iter().any(|p| p.screen.text().contains("TETHER_ORIGINAL"))
    })
    .await;
    assert_eq!(snap.windows[0].name, "External change");
    restored.perform(Action::ClosePane(other)).await.unwrap();
    wait(&restored, |s| s.panes.len() == 1).await;
    restored.detach();
}

/// A path printed in a pane is found in that pane, and a pane whose shell
/// reports its directory says so — the two things pointing at output needs,
/// the same as for a terminal of its own.
#[tokio::test]
async fn a_pane_names_what_its_output_points_at() {
    if Command::new("tmux").arg("-V").output().is_err() {
        assert!(std::env::var_os("TETHER_REQUIRE_TMUX").is_none(), "tmux is required");
        return;
    }
    let server = Server(format!(
        "tether-link-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    assert!(
        server
            .command(&[
                "-f",
                "/dev/null",
                "new-session",
                "-d",
                "-s",
                "test",
                "-x",
                "80",
                "-y",
                "20",
                "sh"
            ])
            .status
            .success()
    );
    let workspace = server.attach();
    let pane = wait(&workspace, |s| s.panes.len() == 1).await.panes[0].info.id;
    workspace
        .write(pane, b"printf '\\033]7;file://h/tmp/runs\\007wrote out/pl''ot.png\\n'\r".to_vec())
        .unwrap();
    let snapshot = wait(&workspace, |s| {
        s.panes[0].screen.text().lines().any(|line| line.starts_with("wrote out/plot.png"))
    })
    .await;
    let row = snapshot.panes[0]
        .screen
        .text()
        .lines()
        .position(|line| line.starts_with("wrote out/plot.png"))
        .unwrap() as u16;

    let link = workspace.link_at(pane, Position::new(row, 8)).expect("a link");
    assert_eq!(link.text, "out/plot.png");
    assert_eq!(workspace.working_directory(pane).as_deref(), Some("/tmp/runs"));
    assert_eq!(workspace.link_at(pane + 1000, Position::new(row, 8)), None, "no such pane");
    workspace.detach();
}

#[test]
fn names_cannot_inject_lines_or_shell_commands() {
    assert!(tether_tmux::quote("bad\nkill-server").is_err());
    assert!(tether_tmux::quote("bad\0name").is_err());
    assert_eq!(
        tether_tmux::quote("it's $(touch /tmp/nope); ok").unwrap(),
        "'it'\\''s $(touch /tmp/nope); ok'"
    );
}

#[tokio::test]
async fn attach_restores_full_screen_modes_and_unicode() {
    if Command::new("tmux").arg("-V").output().is_err() {
        return;
    }
    let server = Server(format!(
        "tether-modes-{}",
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    assert!(
        server
            .command(&[
                "-f",
                "/dev/null",
                "new-session",
                "-d",
                "-s",
                "test",
                "-x",
                "80",
                "-y",
                "24",
                "sh"
            ])
            .status
            .success()
    );
    // Leave a full-screen application active before the native client attaches.
    server.command(&[
        "send-keys",
        "-t",
        "test",
        "printf '\\033[?1049h\\033[?2004h\\033[?1h\\033[?25l你好 TETHER_FULLSCREEN'; sleep 30",
        "Enter",
    ]);
    for _ in 0..100 {
        if String::from_utf8_lossy(
            &server.command(&["display-message", "-p", "-t", "test", "#{alternate_on}"]).stdout,
        )
        .trim()
            == "1"
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let workspace = server.attach();
    let snap = wait(&workspace, |s| {
        s.panes.first().is_some_and(|p| {
            p.screen.text().contains("TETHER_FULLSCREEN") && p.screen.modes.bracketed_paste
        })
    })
    .await;
    let screen = &snap.panes[0].screen;
    assert!(screen.modes.alternate_screen);
    assert!(screen.modes.application_cursor_keys);
    assert!(!screen.cursor.visible);
    assert!(screen.text().contains("你好"));
    workspace.detach();
}

struct Fragmented {
    bytes: VecDeque<Vec<u8>>,
}
use std::collections::VecDeque;
#[async_trait::async_trait]
impl Transport for Fragmented {
    async fn read(&mut self) -> tether_tmux::Result<Option<Vec<u8>>> {
        if let Some(bytes) = self.bytes.pop_front() {
            Ok(Some(bytes))
        } else {
            std::future::pending().await
        }
    }
    async fn write(&mut self, _: &[u8]) -> tether_tmux::Result<()> {
        Ok(())
    }
    async fn close(&mut self) {}
}
#[tokio::test]
async fn fragmented_responses_and_cancellation_of_a_silent_peer() {
    let transcript = b"%begin 1 1 0\n%end 1 1 0\n%begin 1 2 1\n@0 1 80 24 fixture\n%end 1 2 1\n%begin 1 3 1\n%end 1 3 1\n";
    let workspace =
        Workspace::start(Fragmented { bytes: transcript.chunks(3).map(Vec::from).collect() });
    let snap = wait(&workspace, |s| s.windows.len() == 1).await;
    assert_eq!(snap.windows[0].name, "fixture");
    workspace.detach();
    tokio::time::timeout(Duration::from_secs(1), async { while workspace.changed().await {} })
        .await
        .unwrap();
    assert_eq!(workspace.snapshot().ended.as_deref(), Some("Detached"));
}

#[tokio::test]
async fn oversized_remote_line_fails_without_unbounded_buffering() {
    let workspace =
        Workspace::start(Fragmented { bytes: VecDeque::from([vec![b'x'; 4 * 1024 * 1024 + 1]]) });
    tokio::time::timeout(Duration::from_secs(2), async { while workspace.changed().await {} })
        .await
        .unwrap();
    assert!(workspace.snapshot().ended.unwrap().contains("exceeds limit"));
}
