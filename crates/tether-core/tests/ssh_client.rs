//! Attaching through an OpenSSH client, without a stand-in binary.
//!
//! A script written to a temp directory and executed at once is not a stable
//! stand-in: Linux can refuse it with "text file busy", and one read of its
//! stdout can return before the script has finished writing. A live cluster
//! is what the app is for.

use tether_core::{Connection, SshClient};

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
