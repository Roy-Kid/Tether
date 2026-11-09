//! What closing a terminal could interrupt: the Mac `ShellActivity`.
//!
//! A process listing of the terminal's tty, framed so a login banner is not
//! read as a row. Only the waiting root shell is idle; nested shells,
//! background and stopped jobs all count. A listing that is incomplete,
//! ambiguous or missing proves nothing, and says nothing is known.

use std::collections::{HashMap, HashSet};

use crate::foreground::SHELLS;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Activity {
    Idle,
    Running(Vec<String>),
    Unknown,
}

impl Activity {
    /// The one line a close confirmation adds. "May": a process can outlive
    /// its terminal, and when nothing could be checked nothing is claimed.
    pub fn close_message(&self) -> Option<String> {
        match self {
            Self::Idle => None,
            Self::Running(names) => Some(format!("{} may stop.", list(names))),
            Self::Unknown => Some("Anything running here may stop.".into()),
        }
    }
}

/// `comm` keeps command arguments out of it.
pub const LIST_COMMAND: &str = "printf '%s\\n' TETHER-PROCESSES; LC_ALL=C ps -ax -o pid= -o ppid= -o tty= -o stat= -o comm= && printf '%s\\n' TETHER-PROCESSES-END";

struct Row {
    pid: u64,
    parent: u64,
    tty: Option<String>,
    state: String,
    name: String,
}

fn row(line: &str) -> Option<Row> {
    let mut parts = line.split_whitespace();
    let pid = parts.next()?.parse().ok()?;
    let parent = parts.next()?.parse().ok()?;
    let tty = device(parts.next()?);
    let state = parts.next()?.to_owned();
    let command = parts.collect::<Vec<_>>().join(" ");
    if command.is_empty() {
        return None;
    }
    let name = command.rsplit('/').next().unwrap_or(&command).to_owned();
    Some(Row { pid, parent, tty, state, name })
}

/// `ShellTTY.device`: `ttys012` or `pts/5` as a device path; `?` is none.
pub fn device(tty: &str) -> Option<String> {
    if matches!(tty, "?" | "??" | "-") {
        return None;
    }
    let path = if tty.starts_with('/') { tty.to_owned() } else { format!("/dev/{tty}") };
    is_device(&path).then_some(path)
}

pub fn is_device(path: &str) -> bool {
    ["/dev/pts/", "/dev/ttys"].iter().any(|prefix| {
        path.strip_prefix(prefix)
            .is_some_and(|rest| !rest.is_empty() && rest.chars().all(|c| c.is_ascii_digit()))
    })
}

pub fn parse(text: &str, terminal: &str) -> Activity {
    let lines: Vec<&str> = text.lines().collect();
    let start = lines.iter().position(|line| *line == "TETHER-PROCESSES");
    let end = lines.iter().position(|line| *line == "TETHER-PROCESSES-END");
    let (Some(start), Some(end)) = (start, end) else { return Activity::Unknown };
    if !is_device(terminal) || start >= end {
        return Activity::Unknown;
    }
    let body = &lines[start + 1..end];
    let processes: Vec<Row> = body.iter().filter_map(|line| row(line)).collect();
    if processes.len() != body.len() {
        return Activity::Unknown;
    }
    let on_tty: Vec<&Row> =
        processes.iter().filter(|r| r.tty.as_deref() == Some(terminal)).collect();
    let tty_pids: HashSet<u64> = on_tty.iter().map(|r| r.pid).collect();
    let roots: Vec<&&Row> = on_tty.iter().filter(|r| !tty_pids.contains(&r.parent)).collect();
    let [shell] = roots.as_slice() else { return Activity::Unknown };
    let mut children: HashMap<u64, Vec<u64>> = HashMap::new();
    for row in &processes {
        children.entry(row.parent).or_default().push(row.pid);
    }
    let mut owned = tty_pids.clone();
    let mut stack: Vec<u64> = owned.iter().copied().collect();
    while let Some(pid) = stack.pop() {
        for child in children.get(&pid).into_iter().flatten() {
            if owned.insert(*child) {
                stack.push(*child);
            }
        }
    }
    let mut running: Vec<String> = processes
        .iter()
        .filter(|r| {
            owned.contains(&r.pid) && !r.state.starts_with('Z') && !r.state.starts_with('X')
        })
        .filter(|r| {
            let waiting = r.pid == shell.pid
                && SHELLS.contains(&r.name.trim_start_matches('-'))
                && (r.state.starts_with('S') || r.state.starts_with('I'));
            !waiting
        })
        .map(|r| r.name.clone())
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    running.sort();
    if running.is_empty() { Activity::Idle } else { Activity::Running(running) }
}

/// `ListFormatter` in English: `a`, `a and b`, `a, b, and c`.
fn list(names: &[String]) -> String {
    match names {
        [] => String::new(),
        [one] => one.clone(),
        [a, b] => format!("{a} and {b}"),
        [rest @ .., last] => format!("{}, and {last}", rest.join(", ")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn activity(rows: &str) -> Activity {
        parse(&format!("banner\nTETHER-PROCESSES\n{rows}\nTETHER-PROCESSES-END\n"), "/dev/pts/5")
    }

    // `ShellActivityTests.jobs`.
    #[test]
    fn foreground_background_and_stopped_jobs_all_need_confirmation() {
        for state in ["S+", "S", "T"] {
            let rows = format!("100 1 pts/5 Ss bash\n101 100 pts/5 {state} /usr/bin/sleep");
            assert_eq!(activity(&rows), Activity::Running(vec!["sleep".into()]), "{state}");
        }
    }

    // `ShellActivityTests.replacedShell`.
    #[test]
    fn exec_replacing_the_shell_and_a_busy_shell_are_not_idle() {
        assert_eq!(activity("100 1 pts/5 Ss /usr/bin/vim"), Activity::Running(vec!["vim".into()]));
        assert_eq!(activity("100 1 pts/5 Rs bash"), Activity::Running(vec!["bash".into()]));
    }

    // `ShellActivityTests.unknown`.
    #[test]
    fn failed_ambiguous_and_incomplete_listings_prove_nothing() {
        assert_eq!(parse("100 1 pts/5 S bash", "/dev/pts/5"), Activity::Unknown);
        assert_eq!(activity(""), Activity::Unknown);
        assert_eq!(activity("100 1 pts/8 Ss bash"), Activity::Unknown);
        assert_eq!(activity("100 1 pts/5 Ss bash\n101 1 pts/5 S zsh"), Activity::Unknown);
        assert_eq!(activity("100 1 pts/5 Ss bash\ntruncated"), Activity::Unknown);
    }

    #[test]
    fn a_waiting_shell_is_idle_on_a_mac_tty() {
        let text = "TETHER-PROCESSES\n300 1 ttys012 Ss -zsh\nTETHER-PROCESSES-END";
        assert_eq!(parse(text, "/dev/ttys012"), Activity::Idle);
    }

    #[test]
    fn the_message_lists_what_may_stop() {
        assert_eq!(Activity::Idle.close_message(), None);
        let two = Activity::Running(vec!["make".into(), "vim".into()]);
        assert_eq!(two.close_message().as_deref(), Some("make and vim may stop."));
        let three = Activity::Running(vec!["a".into(), "b".into(), "c".into()]);
        assert_eq!(three.close_message().as_deref(), Some("a, b, and c may stop."));
    }
}
