//! What a terminal's chip says: the Mac `TerminalLabels`.
//!
//! A pinned name is kept as typed. Otherwise the chip shows the attached
//! session, then the foreground program, then the directory, then
//! `Terminal N`. When two or more automatic names are the same word, each
//! gains a number in strip order: `ssh 1`, `ssh 2`.

use std::collections::HashMap;

use crate::split::PaneId;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Label {
    pub id: Option<PaneId>,
    /// Rename Terminal. While set, activity does not change the chip.
    pub pinned: Option<String>,
    /// Attached session name, when this terminal is a client of one.
    pub session: Option<String>,
    /// Foreground program. `None` while the shell is at its prompt.
    pub command: Option<String>,
    /// Last path component, or `~` for the home directory.
    pub directory: Option<String>,
    /// `Terminal N`, the fallback.
    pub serial: String,
}

/// Chip titles for the terminals on one host, in strip order.
pub fn titles(rows: &[Label]) -> HashMap<PaneId, String> {
    let bases: Vec<(String, bool)> = rows.iter().map(base).collect();
    let mut counts: HashMap<&str, usize> = HashMap::new();
    for (text, automatic) in &bases {
        if *automatic {
            *counts.entry(text.as_str()).or_default() += 1;
        }
    }
    let mut seen: HashMap<&str, usize> = HashMap::new();
    let mut result = HashMap::new();
    for (row, (text, automatic)) in rows.iter().zip(&bases) {
        let Some(id) = row.id else { continue };
        let twins = if *automatic { counts.get(text.as_str()).copied().unwrap_or(0) } else { 0 };
        let title = if twins > 1 {
            let number = seen.entry(text.as_str()).or_default();
            *number += 1;
            format!("{text} {number}")
        } else {
            text.clone()
        };
        result.insert(id, title);
    }
    result
}

/// The word Rename Terminal starts from: the pin, or the automatic name without its number.
pub fn seed(row: &Label) -> String {
    base(row).0
}

/// `~` for the home directory, the last component otherwise, nothing for `/`.
pub fn directory_name(path: Option<&str>, home: Option<&str>) -> Option<String> {
    let path = path?;
    if !path.starts_with('/') {
        return None;
    }
    let path = trim_slashes(path);
    if let Some(home) = home
        && path == trim_slashes(home)
    {
        return Some("~".to_owned());
    }
    if path == "/" {
        return None;
    }
    cleaned(path.rsplit('/').next())
}

pub fn is_serial(name: &str) -> bool {
    name.strip_prefix("Terminal ")
        .is_some_and(|tail| !tail.is_empty() && tail.chars().all(|c| c.is_ascii_digit()))
}

fn trim_slashes(path: &str) -> &str {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() { "/" } else { trimmed }
}

fn base(row: &Label) -> (String, bool) {
    if let Some(pinned) = cleaned(row.pinned.as_deref()) {
        return (pinned, false);
    }
    let automatic = [&row.session, &row.command, &row.directory]
        .into_iter()
        .find_map(|text| cleaned(text.as_deref()));
    (automatic.unwrap_or_else(|| row.serial.clone()), true)
}

fn cleaned(text: Option<&str>) -> Option<String> {
    let trimmed = text?.trim();
    (!trimmed.is_empty() && !trimmed.contains(['\n', '\r'])).then(|| trimmed.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: u64, serial: &str) -> Label {
        Label { id: Some(PaneId(id)), serial: serial.to_owned(), ..Label::default() }
    }

    // `TerminalChipTests.sshAndPin`.
    #[test]
    fn ssh_tabs_on_one_machine_are_numbered_and_a_pin_clears() {
        let first = Label { command: Some("ssh".into()), ..row(1, "Terminal 1") };
        let second = Label { command: Some("ssh".into()), ..row(2, "Terminal 2") };
        let named = titles(&[first.clone(), second.clone()]);
        assert_eq!(named[&PaneId(1)], "ssh 1");
        assert_eq!(named[&PaneId(2)], "ssh 2");
        assert_eq!(seed(&second), "ssh");

        let pinned = Label { pinned: Some("bastion".into()), ..first.clone() };
        let named = titles(&[pinned, second.clone()]);
        assert_eq!(named[&PaneId(1)], "bastion");
        assert_eq!(named[&PaneId(2)], "ssh");

        let blank = Label { pinned: Some(" ".into()), ..first };
        let named = titles(&[blank, second]);
        assert_eq!(named[&PaneId(1)], "ssh 1");
    }

    // `TerminalChipTests.tmuxSession`.
    #[test]
    fn a_session_is_the_chip_ahead_of_the_program() {
        let terminal = Label {
            session: Some("dev".into()),
            command: Some("ssh".into()),
            directory: directory_name(Some("/Users/ada/work/Nerve"), None),
            ..row(1, "Terminal 1")
        };
        assert_eq!(titles(&[terminal])[&PaneId(1)], "dev");
    }

    #[test]
    fn the_directory_then_the_serial() {
        let home = Label {
            directory: directory_name(Some("/Users/ada/"), Some("/Users/ada")),
            ..row(1, "Terminal 1")
        };
        let bare = row(2, "Terminal 2");
        let named = titles(&[home, bare]);
        assert_eq!(named[&PaneId(1)], "~");
        assert_eq!(named[&PaneId(2)], "Terminal 2");
        assert_eq!(directory_name(Some("/"), None), None);
        assert_eq!(directory_name(Some("relative"), None), None);
        assert_eq!(directory_name(Some("/srv/app//"), None), Some("app".into()));
    }

    #[test]
    fn a_serial_is_terminal_and_a_number() {
        assert!(is_serial("Terminal 3"));
        assert!(!is_serial("Terminal"));
        assert!(!is_serial("Terminal x"));
        assert!(!is_serial("api"));
    }
}
