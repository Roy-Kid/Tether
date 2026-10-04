use std::collections::VecDeque;
use std::time::Duration;

use tether_tmux::{Snapshot, Transport, Workspace};

struct Fragmented {
    bytes: VecDeque<Vec<u8>>,
}

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
