//! Stand-in for `ssh -W`, compiled by the forward test.
//!
//! A pipe is not a terminal. One read has to return the bytes already
//! waiting, then the program has to write them on. Filling a large buffer
//! first would hold a request until the browser closed the connection.

use std::env;
use std::io::{self, Read, Write};
use std::net::{Shutdown, TcpStream};
use std::process::ExitCode;
use std::thread;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.iter().any(|arg| arg == "-O") {
        return ExitCode::SUCCESS;
    }
    let Some(spec) = args.windows(2).find(|pair| pair[0] == "-W").map(|pair| pair[1].as_str())
    else {
        return ExitCode::from(2);
    };
    let Some((host, port)) = spec.rsplit_once(':') else {
        return ExitCode::from(2);
    };
    let Ok(port) = port.parse::<u16>() else {
        return ExitCode::from(2);
    };
    let Ok(mut remote) = TcpStream::connect((host, port)) else {
        return ExitCode::from(1);
    };
    let Ok(mut outbound) = remote.try_clone() else {
        return ExitCode::from(1);
    };

    thread::spawn(move || {
        let mut input = io::stdin().lock();
        let mut buf = [0u8; 8 * 1024];
        loop {
            let read = match input.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(read) => read,
            };
            if outbound.write_all(&buf[..read]).is_err() {
                break;
            }
        }
        let _ = outbound.shutdown(Shutdown::Write);
    });

    let mut output = io::stdout().lock();
    let mut buf = [0u8; 8 * 1024];
    loop {
        let read = match remote.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(read) => read,
        };
        if output.write_all(&buf[..read]).is_err() || output.flush().is_err() {
            break;
        }
    }
    ExitCode::SUCCESS
}
