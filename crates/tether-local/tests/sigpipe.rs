//! A program that stopped reading must not take this process with it.
//!
//! Writing to a pipe nobody reads raises `SIGPIPE`, whose default action is
//! to end the process. A Rust binary never sees that — the standard library
//! ignores the signal before `main` — so every test here passed while an
//! application embedding this crate, which starts with the default, was one
//! exited child away from vanishing. Measured: the Swift suite died with
//! signal 13 in three runs out of ten, when a tmux client had exited before
//! the newline that detaches it was written.
//!
//! Its own test binary, because restoring the default is process-wide and a
//! failure here is the process ending.

#![cfg(any(target_os = "macos", target_os = "ios"))]

use std::time::Duration;

use tether_local::{Command, Stream};

#[tokio::test]
async fn writing_to_a_program_that_has_gone_is_an_error_not_a_signal() {
    // What an application that is not written in Rust starts with.
    // SAFETY: setting a signal's disposition to its default is async-signal
    // safe, and nothing in this binary relies on the Rust default.
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL) };

    let mut stream = Stream::start(&Command::new("/bin/sh").arg("-c").arg("exec 0<&-; exit 0"))
        .expect("a child");
    tokio::time::sleep(Duration::from_millis(200)).await;

    let mut refused = false;
    for _ in 0..64 {
        if stream.write(&[b'x'; 64 * 1024]).await.is_err() {
            refused = true;
            break;
        }
    }
    assert!(refused, "the pipe should refuse once nobody reads it");
    stream.close().await;
}
