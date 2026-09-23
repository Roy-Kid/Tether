//! Running a command on this machine *without* giving it a terminal.
//!
//! [`Shell`] exists because a person is going to look at the output. This
//! exists because a program is: control protocols, one-shot queries, anything
//! whose answer is parsed rather than drawn. The difference is a pseudo-
//! terminal, and it is not a detail — a pty echoes what is written to it and
//! rewrites the line endings coming back, which corrupts a protocol that
//! counts on neither happening.
//!
//! So this is the same crate's other half: pipes, stdout and stderr kept
//! apart, and an exit status. Still no interpretation of the bytes, and still
//! nothing here that knows what the far side is speaking (spec §8).
//!
//! [`Shell`]: crate::Shell

use std::process::Stdio;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, ChildStderr, ChildStdin, ChildStdout};

use crate::command::Command;
use crate::error::LocalError;
use crate::shell::FOREIGN_TERMINAL_CLAIMS;

/// What one read from a pipe may return.
const CHUNK: usize = 8 * 1024;

/// Everything a finished command left behind.
///
/// Both streams, kept apart, because this is the half of the crate whose
/// output is parsed: a query's answer is on stdout and the reason it failed
/// is on stderr, and merging them would put a warning in the middle of the
/// data. (A [`Shell`] merges them, for the opposite and equally good reason.)
///
/// [`Shell`]: crate::Shell
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Capture {
    /// The exit status, or `None` if a signal ended the program.
    pub status: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

impl Capture {
    /// Whether the program said it succeeded.
    pub fn succeeded(&self) -> bool {
        self.status == Some(0)
    }
}

/// A command's standard input and output, held open.
///
/// The duplex counterpart to [`Capture`]: a program that is spoken to and
/// answers, for as long as both ends stay interested. Dropping it closes the
/// pipes, which is how the child is told to stop.
pub struct Stream {
    child: Child,
    stdin: Option<ChildStdin>,
    stdout: ChildStdout,
    /// Taken away once it reaches its end, so the branch that watches it
    /// stops being ready. A closed pipe reads zero bytes without waiting,
    /// and a `select!` arm that is always ready is a spin.
    stderr: Option<ChildStderr>,
}

impl Stream {
    /// Starts `command` with its standard streams on pipes.
    pub fn start(command: &Command) -> Result<Self, LocalError> {
        let mut child = spawn(command, Stdio::piped())?;
        // `spawn` asked for all three pipes, so both are present. Taking them
        // rather than borrowing is what lets a read and a write be in flight
        // at the same time without borrowing the child twice.
        let stdin = child.stdin.take();
        if let Some(stdin) = &stdin {
            refuse_broken_pipe_signal(stdin);
        }
        let stdout = child.stdout.take().ok_or(LocalError::Ended)?;
        let stderr = child.stderr.take();
        Ok(Self { child, stdin, stdout, stderr })
    }

    /// The next bytes the program wrote, or `None` once it will write no more.
    ///
    /// Anything on standard error is a failure rather than more output. A
    /// program being spoken to in a protocol answers on standard output; what
    /// it puts on the other stream is a complaint, and mixing the two into
    /// one byte stream would feed the complaint to a parser as if it were an
    /// answer. It is also why the stream is read at all: a pipe nobody empties
    /// fills, and a program blocked writing to it never speaks again.
    ///
    /// Cancel-safe: a read from a pipe either takes bytes or does nothing, so
    /// a caller parked on this inside a `select!` loses none when something
    /// else wakes first.
    pub async fn read(&mut self) -> Result<Option<Vec<u8>>, LocalError> {
        let mut out = vec![0u8; CHUNK];
        let mut err = vec![0u8; CHUNK];

        loop {
            let complaint = tokio::select! {
                read = self.stdout.read(&mut out) => {
                    let read = read.map_err(|error| LocalError::Write { cause: error.to_string() })?;
                    if read == 0 {
                        return Ok(None);
                    }
                    out.truncate(read);
                    return Ok(Some(out));
                }
                read = read_from(&mut self.stderr, &mut err) => read?,
            };

            // The stream reached its end rather than saying anything. Nothing
            // to report, and nothing left to watch.
            match complaint {
                Some(cause) => {
                    return Err(LocalError::NotStarted {
                        program: "the command".to_owned(),
                        cause,
                    });
                }
                None => continue,
            }
        }
    }

    pub async fn write(&mut self, bytes: &[u8]) -> Result<(), LocalError> {
        let stdin = self.stdin.as_mut().ok_or(LocalError::Ended)?;
        stdin.write_all(bytes).await.map_err(|error| LocalError::Write { cause: error.to_string() })
    }

    /// Closes the program's input and stops waiting for it.
    ///
    /// Input first: a program that ends when its input does — which is most
    /// of them — then gets to finish what it was saying rather than being
    /// killed mid-sentence. Only if it is still running afterwards is it
    /// stopped, because a child nobody reaps is a zombie for the life of the
    /// process.
    pub async fn close(&mut self) {
        drop(self.stdin.take());
        let _ = self.child.start_kill();
        let _ = self.child.wait().await;
    }
}

/// Makes a write to a program that stopped reading fail with `EPIPE`
/// instead of raising `SIGPIPE`.
///
/// The signal's default action ends the process. A Rust binary ignores it
/// before `main`, which is why no Rust test ever saw this; an application
/// that embeds this crate starts with the default, and a tmux client or an
/// `sftp-server` exiting a moment before our last write was enough to take
/// the whole app with it. Per descriptor rather than process-wide: what an
/// application does with its own signals is its business.
#[cfg(any(target_os = "macos", target_os = "ios"))]
fn refuse_broken_pipe_signal(stdin: &ChildStdin) {
    use std::os::fd::AsRawFd;
    /// `<sys/fcntl.h>`; the `libc` crate does not carry it.
    const F_SETNOSIGPIPE: libc::c_int = 73;
    // SAFETY: `fcntl` on a descriptor this process owns and keeps open for
    // the duration of the call; the flag only changes how a later write to
    // it fails.
    unsafe { libc::fcntl(stdin.as_raw_fd(), F_SETNOSIGPIPE, 1) };
}

/// Elsewhere there is no per-descriptor switch. The consumers there are Rust
/// programs, which ignore the signal already.
#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn refuse_broken_pipe_signal(_: &ChildStdin) {}

/// Waits on a pipe that may already be finished.
///
/// `None` once it ends, and the handle is dropped so this never becomes ready
/// again — otherwise the `select!` above would spin on a closed stream. A
/// handle that is already gone waits for ever, which is what "there is
/// nothing here to watch" has to mean inside a `select!`.
async fn read_from(
    pipe: &mut Option<ChildStderr>,
    buffer: &mut [u8],
) -> Result<Option<String>, LocalError> {
    let Some(stderr) = pipe.as_mut() else {
        return std::future::pending().await;
    };

    match stderr.read(buffer).await {
        Ok(0) | Err(_) => {
            *pipe = None;
            Ok(None)
        }
        Ok(read) => Ok(Some(String::from_utf8_lossy(&buffer[..read]).trim().to_owned())),
    }
}

impl Command {
    /// Runs this command to completion and collects what it produced.
    ///
    /// `limit` bounds each stream. A command whose output is parsed has an
    /// expected size; one that exceeds it is either the wrong command or a
    /// program in a loop, and reading it to the end would answer a mistake
    /// by exhausting memory.
    pub async fn capture(&self, limit: usize) -> Result<Capture, LocalError> {
        let mut child = spawn(self, Stdio::null())?;
        let mut stdout = child.stdout.take().ok_or(LocalError::Ended)?;
        let mut stderr = child.stderr.take().ok_or(LocalError::Ended)?;

        // Both at once, and abandoned together. Reading one to the end first
        // would deadlock on a program that fills the other pipe while waiting
        // to be read — and a program that blew the limit on one stream is
        // still filling the other, so waiting for that one to end would hang
        // on exactly the runaway this refuses to collect.
        let collected = tokio::try_join!(drain(&mut stdout, limit), drain(&mut stderr, limit));

        let (out, err) = match collected {
            Ok(both) => both,
            Err(refused) => {
                let _ = child.start_kill();
                let _ = child.wait().await;
                return Err(refused);
            }
        };

        let status = child
            .wait()
            .await
            .map_err(|error| LocalError::NotStarted {
                program: self.program_name().to_owned(),
                cause: error.to_string(),
            })?
            .code();

        Ok(Capture { status, stdout: out, stderr: err })
    }
}

/// Reads a pipe to its end, refusing to grow past `limit`.
async fn drain(
    pipe: &mut (impl tokio::io::AsyncRead + Unpin),
    limit: usize,
) -> Result<Vec<u8>, LocalError> {
    let mut collected = Vec::new();
    let mut buffer = vec![0u8; CHUNK];

    loop {
        let read = pipe
            .read(&mut buffer)
            .await
            .map_err(|error| LocalError::Write { cause: error.to_string() })?;
        if read == 0 {
            return Ok(collected);
        }
        if collected.len() + read > limit {
            return Err(LocalError::Write {
                cause: format!("the command produced more than {limit} bytes"),
            });
        }
        collected.extend_from_slice(&buffer[..read]);
    }
}

fn spawn(command: &Command, stdin: Stdio) -> Result<Child, LocalError> {
    // iOS forbids an application from starting another process at all.
    // Checked before anything is opened, so the failure is the true one
    // rather than whichever system call happens to be refused first.
    if cfg!(target_os = "ios") {
        return Err(LocalError::Unsupported);
    }

    let (program, arguments, directory, term) = command.parts();
    let mut builder = tokio::process::Command::new(program);
    builder
        .args(arguments)
        .env("TERM", term)
        .stdin(stdin)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // Not a terminal window and never will be. The same claims a shell
        // must not inherit would be just as untrue here.
        .kill_on_drop(true);

    for claim in FOREIGN_TERMINAL_CLAIMS {
        builder.env_remove(claim);
    }
    if let Some(directory) = directory {
        builder.current_dir(directory);
    }

    builder.spawn().map_err(|error| LocalError::NotStarted {
        program: program.to_owned(),
        cause: error.to_string(),
    })
}

/// Unix-only: the cases drive `/bin/sh` and `/bin/cat`. Windows gets its own
/// dialect (ConPTY + cmd/pwsh) when `tether-local` is ported.
#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_command_reports_what_it_wrote_and_how_it_ended() {
        let captured = Command::new("/bin/sh")
            .arg("-c")
            .arg("printf out; printf err >&2; exit 3")
            .capture(64 * 1024)
            .await
            .expect("the shell should have run");

        assert_eq!(captured.status, Some(3));
        assert_eq!(captured.stdout, b"out");
        assert_eq!(captured.stderr, b"err");
        assert!(!captured.succeeded());
    }

    #[tokio::test]
    async fn output_past_the_limit_is_refused_rather_than_collected() {
        let result =
            Command::new("/bin/sh").arg("-c").arg("yes 0123456789").capture(4 * 1024).await;

        assert!(matches!(result, Err(LocalError::Write { .. })), "got {result:?}");
    }

    #[tokio::test]
    async fn a_program_that_does_not_exist_says_so_in_our_words() {
        let result = Command::new("/nonexistent/tether-probe").capture(1024).await;

        assert!(matches!(result, Err(LocalError::NotStarted { .. })), "got {result:?}");
    }

    #[tokio::test]
    async fn a_stream_carries_bytes_both_ways() {
        let mut stream = Stream::start(&Command::new("/bin/cat")).expect("cat should start");

        stream.write(b"ping\n").await.expect("the pipe should accept a write");
        let echoed =
            stream.read().await.expect("cat should answer").expect("and not be at its end");

        assert_eq!(echoed, b"ping\n");
        stream.close().await;
    }

    #[tokio::test]
    async fn a_complaint_on_standard_error_is_a_failure_not_more_output() {
        let mut stream =
            Stream::start(&Command::new("/bin/sh").arg("-c").arg("echo nope >&2; cat"))
                .expect("sh should start");

        let result = stream.read().await;

        assert!(
            matches!(&result, Err(LocalError::NotStarted { cause, .. }) if cause == "nope"),
            "got {result:?}"
        );
        stream.close().await;
    }

    /// The reason this is not a [`crate::Shell`]: a pseudo-terminal would
    /// have echoed the write back and turned the newline into a carriage
    /// return and a newline, both of which a control protocol reads as data.
    #[tokio::test]
    async fn a_stream_does_not_echo_what_was_written_to_it() {
        let mut stream = Stream::start(
            &Command::new("/bin/sh").arg("-c").arg("read line; printf '%s\\n' \"$line\""),
        )
        .expect("sh should start");

        stream.write(b"quiet\n").await.expect("the pipe should accept a write");
        let answer = stream.read().await.expect("sh should answer").expect("and not be at its end");

        assert_eq!(answer, b"quiet\n", "a pty would have returned the echo first");
        stream.close().await;
    }
}
