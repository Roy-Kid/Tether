//! Windows: the shell that opens is one this machine could run.
#![cfg(windows)]

use tether_local::Command;

#[test]
fn a_login_shell_resolves_to_something_on_this_machine() {
    let command = Command::login_shell();
    let program = command.program_name();
    assert!(!program.is_empty());
    // pwsh, powershell or cmd — what every other terminal here would pick.
    let name = program.rsplit(['/', char::from(92)]).next().unwrap_or(program);
    let name = name.strip_suffix(".exe").unwrap_or(name).to_ascii_lowercase();
    assert!(name == "pwsh" || name == "powershell" || name == "cmd", "got {program}");
}

#[test]
fn a_named_cmd_shell_carries_no_login_flag() {
    let command = Command::shell("cmd.exe");
    let debug = format!("{command:?}");
    assert!(!debug.contains("\"-l\""), "cmd must not get -l: {debug}");
}

fn console_probe() -> Command {
    let windows = std::env::var("SystemRoot").expect("Windows system directory");
    Command::new(format!(r"{windows}\System32\WindowsPowerShell\v1.0\powershell.exe"))
        .arg("-NoLogo")
        .arg("-NoProfile")
        .arg("-NonInteractive")
        .arg("-Command")
        .arg(
            r#"Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class ConsoleProbe { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }'; [Console]::Out.WriteLine([ConsoleProbe]::GetConsoleWindow().ToInt64()); [Console]::Error.WriteLine('stderr-marker'); exit 7"#,
        )
}

#[tokio::test]
async fn captured_helpers_have_no_console_and_preserve_output_and_exit_status() {
    let result = console_probe().capture(4096).await.expect("capture console probe");
    assert_eq!(String::from_utf8_lossy(&result.stdout).trim(), "0", "helper allocated a console");
    assert_eq!(String::from_utf8_lossy(&result.stderr).trim(), "stderr-marker");
    assert_eq!(result.status, Some(7));
}

#[tokio::test]
async fn streaming_helpers_have_no_console() {
    use tokio::io::AsyncReadExt;

    let stream = tether_local::Stream::start(&console_probe()).expect("stream console probe");
    let (mut child, stdin, mut stdout, stderr) = stream.into_stdio();
    drop(stdin);
    let mut output = String::new();
    stdout.read_to_string(&mut output).await.expect("read console handle");
    let mut error = String::new();
    stderr.expect("stderr pipe").read_to_string(&mut error).await.expect("read stderr");
    assert_eq!(output.trim(), "0", "helper allocated a console");
    assert_eq!(error.trim(), "stderr-marker");
    assert_eq!(child.wait().await.expect("child exit").code(), Some(7));
}
