//! A port on the far side, opened from this machine, without a second login.
//!
//! The echo is a real TCP listener. What is under test is the copy: through
//! a direct-tcpip channel on the in-process server, and through `ssh -W`
//! when the lease is an OpenSSH client.

#[allow(dead_code)]
#[path = "../../tether-ssh/tests/support/mod.rs"]
mod support;

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use tether_core::ssh::Endpoint;
use tether_core::terminal::ScreenSize;
use tether_core::{Connection, Credential, Dial, SshClient};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

#[tokio::test]
async fn a_remote_port_is_reached_through_the_authenticated_session() {
    let echo = echo_server().await;
    let connection = authenticated().await;

    let forwarded = connection.listen(echo.port()).await.expect("listen");
    assert!(!forwarded.already_local());
    let local = forwarded.local_port();

    let mut client = TcpStream::connect(("127.0.0.1", local)).await.expect("local port");
    client.write_all(b"ping").await.expect("write");
    let mut got = [0u8; 4];
    tokio::time::timeout(Duration::from_secs(5), client.read_exact(&mut got))
        .await
        .expect("echo timed out")
        .expect("echo");
    assert_eq!(&got, b"ping");

    drop(client);
    drop(forwarded);
    assert!(port_is_free(local).await, "dropping the forward keeps the local port");
}

#[tokio::test]
async fn an_ipv6_loopback_listener_is_reached_after_v4_refuses() {
    let listener = TcpListener::bind("[::1]:0").await.expect("ipv6 echo");
    let port = listener.local_addr().expect("addr").port();
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else { break };
            tokio::spawn(async move {
                let mut buf = vec![0u8; 16];
                loop {
                    match socket.read(&mut buf).await {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            if socket.write_all(&buf[..n]).await.is_err() {
                                break;
                            }
                        }
                    }
                }
            });
        }
    });
    let connection = authenticated_with(support::Policy {
        accepts_key: Some(support::CLIENT_PUBLIC_KEY),
        v4_loopback_refused: true,
        ..support::Policy::default()
    })
    .await;
    let forwarded = connection.listen(port).await.expect("listen");
    let mut client =
        TcpStream::connect(("127.0.0.1", forwarded.local_port())).await.expect("local");
    client.write_all(b"v6").await.expect("write");
    let mut got = [0u8; 2];
    tokio::time::timeout(Duration::from_secs(5), client.read_exact(&mut got))
        .await
        .expect("echo timed out")
        .expect("echo");
    assert_eq!(&got, b"v6");
}

#[tokio::test]
async fn a_taken_local_port_is_not_the_one_that_gets_bound() {
    let echo = echo_server().await;
    let connection = authenticated().await;

    // The echo already listens on this machine, on the same port number the
    // forward would have preferred. The listener has to move aside.
    let forwarded = connection.listen(echo.port()).await.expect("listen");
    assert_ne!(forwarded.local_port(), echo.port());
    let mut client =
        TcpStream::connect(("127.0.0.1", forwarded.local_port())).await.expect("the next port");
    client.write_all(b"next").await.expect("write");
    let mut got = [0u8; 4];
    tokio::time::timeout(Duration::from_secs(5), client.read_exact(&mut got))
        .await
        .expect("echo timed out")
        .expect("echo");
    assert_eq!(&got, b"next");
}

#[tokio::test]
async fn a_local_shell_does_not_listen_over_a_port_already_here() {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("addr").port();

    let forwarded = Connection::Local.listen(port).await.expect("listen");
    assert!(forwarded.already_local());
    assert_eq!(forwarded.local_port(), port);
    // The forward did not take the port: this listener still owns it.
    drop(forwarded);
    assert!(listener.local_addr().is_ok());
}

#[tokio::test]
async fn ports_below_1024_are_refused() {
    let error = Connection::Local.listen(80).await.expect_err("privileged");
    assert!(error.to_string().contains("1024"), "{error}");
}

#[tokio::test]
async fn an_openssh_lease_forwards_with_ssh_w() {
    let echo = echo_server().await;
    let program = fake_ssh_w();
    let connection =
        Connection::OpenSsh(SshClient::new("Arrhenius").program(program.to_string_lossy()));

    let forwarded = connection.listen(echo.port()).await.expect("listen");
    let mut client =
        TcpStream::connect(("127.0.0.1", forwarded.local_port())).await.expect("local");
    client.write_all(b"mux").await.expect("write");
    let mut got = [0u8; 3];
    tokio::time::timeout(Duration::from_secs(5), client.read_exact(&mut got))
        .await
        .expect("echo timed out")
        .expect("echo");
    assert_eq!(&got, b"mux");
}

#[tokio::test]
async fn clones_of_one_session_share_a_lease_id_and_a_redial_does_not() {
    let first = authenticated().await;
    let again = first.clone();
    assert_eq!(first.lease_id(), again.lease_id());
    let redial = authenticated().await;
    assert_ne!(first.lease_id(), redial.lease_id());
    assert_eq!(Connection::Local.lease_id(), Connection::Local.lease_id());
    assert_eq!(Connection::Local.lease_id(), 0);
}

async fn authenticated() -> Connection {
    authenticated_with(support::Policy {
        accepts_key: Some(support::CLIENT_PUBLIC_KEY),
        ..support::Policy::default()
    })
    .await
}

async fn authenticated_with(policy: support::Policy) -> Connection {
    let (address, _) = support::listen(policy).await;
    let dial = Dial::new(Endpoint::new(address.ip().to_string(), address.port()), support::USER)
        .verifier(Arc::new(support::TrustAndRecord::new()))
        .config(support::client_config())
        .size(ScreenSize::new(80, 24));
    let session = dial
        .connect(vec![Credential::PrivateKey {
            pem: support::CLIENT_KEY.to_owned(),
            passphrase: None,
            unlock: None,
        }])
        .await
        .expect("the test key logs in");
    session.connection().expect("a lease")
}

async fn echo_server() -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("echo port");
    let address = listener.local_addr().expect("addr");
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else { break };
            tokio::spawn(async move {
                let mut buf = vec![0u8; 1024];
                loop {
                    match socket.read(&mut buf).await {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            if socket.write_all(&buf[..n]).await.is_err() {
                                break;
                            }
                        }
                    }
                }
            });
        }
    });
    address
}

async fn port_is_free(port: u16) -> bool {
    for _ in 0..50 {
        if TcpListener::bind(("127.0.0.1", port)).await.is_ok() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    false
}

/// An `ssh` that answers `-O check` and splices `-W host:port` to a real socket.
///
/// Compiled here, from the standard library only. The test has to run on a
/// machine with no Python and no netcat; `rustc` is already what built it.
fn fake_ssh_w() -> PathBuf {
    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/support/ssh_w_stub.rs");
    let dir = std::env::temp_dir().join(format!(
        "tether-forward-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("time")
            .as_nanos()
    ));
    std::fs::create_dir_all(&dir).expect("temp");
    let program = dir.join("ssh");
    let compiled = std::process::Command::new("rustc")
        .arg("--edition=2024")
        .arg("-o")
        .arg(&program)
        .arg(&source)
        .output()
        .expect("rustc");
    assert!(
        compiled.status.success(),
        "rustc ssh stub:\n{}",
        String::from_utf8_lossy(&compiled.stderr)
    );
    program
}
