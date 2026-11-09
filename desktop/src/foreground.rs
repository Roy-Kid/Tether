//! The program in front of a local shell, for the terminal's chip: the Mac
//! `LocalForeground`. Reading the process table is the platform's
//! (`platform::foreground_command`); deciding what counts is here.

/// Waiting shells are the prompt, not work. The same set the close check uses.
pub const SHELLS: [&str; 14] = [
    "sh", "bash", "zsh", "fish", "dash", "ash", "ksh", "ksh93", "mksh", "csh", "tcsh", "nu",
    "elvish", "xonsh",
];

/// `foreground` is the terminal's foreground process group. It matches the
/// shell's group while the prompt is waiting.
pub fn picked(shell_group: u32, foreground: u32, leader: Option<&str>) -> Option<String> {
    if foreground == 0 || foreground == shell_group {
        return None;
    }
    let bare = leader?.rsplit('/').next()?;
    let bare = bare.strip_prefix('-').unwrap_or(bare);
    (!bare.is_empty() && !SHELLS.contains(&bare)).then(|| bare.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_prompt_names_nothing() {
        assert_eq!(picked(100, 100, Some("zsh")), None);
        assert_eq!(picked(100, 0, Some("vim")), None);
    }

    #[test]
    fn a_program_in_front_is_named_without_its_path_or_login_dash() {
        assert_eq!(picked(100, 200, Some("/usr/bin/vim")), Some("vim".into()));
        assert_eq!(picked(100, 200, Some("-ssh")), Some("ssh".into()));
        assert_eq!(picked(100, 200, Some("bash")), None);
        assert_eq!(picked(100, 200, None), None);
    }
}
