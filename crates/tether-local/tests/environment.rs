//! What a shell is told about the terminal it is running in.
//!
//! Unix-only: drives `/bin/sh`.
#![cfg(unix)]
//!
//! One test in a file of its own, deliberately. It sets a process-wide
//! environment variable, and sharing a binary with tests that spawn processes
//! would make it race against their reads of the same environment.

use tether_local::{Command, Output, Shell, WindowSize};

async fn output_of(script: &str) -> String {
    let mut shell =
        Shell::open(Command::new("/bin/sh").arg("-c").arg(script), WindowSize::default())
            .expect("a pseudo-terminal");

    let mut text = Vec::new();
    while let Some(output) = shell.next_output().await {
        if let Output::Bytes(bytes) = output {
            text.extend_from_slice(&bytes);
        }
    }
    String::from_utf8_lossy(&text).into_owned()
}

#[tokio::test]
async fn a_shell_is_never_told_it_is_running_in_someone_elses_terminal() {
    // The value is one a real launcher really sets, and the one with
    // consequences: with it, zsh sources `/etc/zshrc_Apple_Terminal` and
    // replays a saved Terminal.app session, so a brand new terminal opens on
    // output from a window somebody closed days ago.
    //
    // SAFETY: this binary holds exactly one test, so nothing else is reading
    // the environment while it is written.
    unsafe {
        std::env::set_var("TERM_PROGRAM", "Apple_Terminal");
        std::env::set_var("TERM_SESSION_ID", "pretend-session");
    }

    let reported =
        output_of("printf '[%s][%s]\\n' \"${TERM_PROGRAM:-unset}\" \"${TERM_SESSION_ID:-unset}\"")
            .await;

    assert!(
        reported.contains("[unset][unset]"),
        "the shell inherited a claim about a terminal it is not in: {reported:?}"
    );
}

#[tokio::test]
async fn but_it_is_told_what_it_may_draw() {
    // The counterpart, and the reason the rule is about claims rather than
    // about environment variables in general: `TERM` is a question this crate
    // can answer honestly, so it is answered rather than removed.
    let reported = output_of("printf '[%s]\\n' \"${TERM:-unset}\"").await;
    assert!(reported.contains("[xterm-256color]"), "got {reported:?}");
}
