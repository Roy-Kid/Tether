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
