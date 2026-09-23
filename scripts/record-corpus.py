#!/usr/bin/env python3
"""Record real terminal workloads as raw byte streams.

Compatibility is driven by testing against real workloads, not by chasing
historical completeness (spec §12). So the corpus under
`crates/tether-terminal/tests/corpus/` is not hand-written escape sequences:
each `.vt` file is what a program actually wrote to a pty at 80x24.

The recordings are committed, which is what makes the test deterministic —
replaying committed bytes needs no vim, no tmux and no network. Re-recording
is a deliberate act, reviewed as a diff like any other change.

Two things this script works hard at:

  * **Isolation.** Every program runs with HOME pointed at a throwaway
    sandbox, so the recording carries this project's fixtures rather than
    whoever ran it: no personal vimrc, no git identity, no shell history.
  * **Redaction.** What leaks anyway — a user name, a home directory — is
    replaced with a padded placeholder of exactly the same byte length, so
    the column arithmetic of the stream survives the substitution.

Usage:  python3 scripts/record-corpus.py [name ...]
"""

from __future__ import annotations

import fcntl
import os
import pty
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path

COLUMNS, ROWS = 80, 24
CORPUS = Path(__file__).resolve().parent.parent / "crates/tether-terminal/tests/corpus"

# A recording that never ends is a hung script, not a test fixture.
IDLE_TIMEOUT = 2.0
HARD_TIMEOUT = 25.0
SIZE_LIMIT = 256 * 1024


def record(command: list[str], keys: list[tuple[float, bytes]], env: dict[str, str]) -> bytes:
    """Run `command` on a pty, type `keys` at the given offsets, return output."""
    master, slave = pty.openpty()
    # The size has to be set on the slave before the fork: a full-screen
    # program asks once, at startup, and a resize after that is a different
    # code path from the one being recorded.
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLUMNS, 0, 0))

    pid = os.fork()
    if pid == 0:
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        for target in (0, 1, 2):
            os.dup2(slave, target)
        if slave > 2:
            os.close(slave)
        os.close(master)
        os.execvpe(command[0], command, env)

    os.close(slave)
    output = bytearray()
    start = time.monotonic()
    pending = list(keys)
    last_read = start

    while True:
        now = time.monotonic()
        if now - start > HARD_TIMEOUT or len(output) > SIZE_LIMIT:
            break
        while pending and pending[0][0] <= now - start:
            os.write(master, pending.pop(0)[1])
        deadline = pending[0][0] - (now - start) if pending else 0.2
        ready, _, _ = select.select([master], [], [], max(0.02, min(0.2, deadline)))
        if ready:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            output.extend(chunk)
            last_read = time.monotonic()
        elif not pending and time.monotonic() - last_read > IDLE_TIMEOUT:
            break

    os.close(master)
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    return bytes(output)


def redact(data: bytes, secret: str, placeholder: str) -> bytes:
    """Replace `secret` with a placeholder of identical byte length.

    Length-preserving on purpose. A terminal stream is full of absolute
    column arithmetic — a substitution that changed a line's width would
    invent a rendering bug that the recorded program never had.
    """
    raw = secret.encode()
    if not raw:
        return data
    fill = (placeholder * len(raw)).encode()[: len(raw)]
    return data.replace(raw, fill)


def scrub(data: bytes, home: Path) -> bytes:
    """Remove the recording machine from the recording.

    A shell prompt inside tmux prints a host name, and a program that reports
    a path prints a home directory. Neither belongs in a fixture committed to
    a public repository, and both are replaced with something of exactly the
    same width.
    """
    host = socket.gethostname()
    for secret, placeholder in (
        (host, "recorder"),
        (host.split(".")[0], "recorder"),
        (os.environ.get("USER", ""), "tether"),
        (str(Path.home()), "/home/tether"),
        (str(home), "/tmp/tether"),
    ):
        data = redact(data, secret, placeholder)
    return data


def sandbox() -> Path:
    """A throwaway HOME with this project's fixtures and nobody's dotfiles.

    A fixed name, not a random one: a shell prompt inside tmux prints the
    working directory, so a random suffix would land in a committed file and
    make every re-recording a diff.
    """
    home = Path(tempfile.gettempdir()) / "tether-corpus"
    shutil.rmtree(home, ignore_errors=True)
    home.mkdir(parents=True)

    (home / ".vimrc").write_text(
        "set nocompatible\nsyntax on\nset number ruler laststatus=2\n"
        "set background=dark noswapfile nobackup\n"
    )
    (home / ".tmux.conf").write_text(
        # The default status line carries a clock, which would put the hour of
        # the recording into a committed file.
        "set -g status-right ''\nset -g status-left '[tether] '\n"
        "set -g default-terminal 'screen-256color'\nset -g history-limit 200\n"
    )
    (home / "sample.rs").write_text(
        "// A file with enough shape for an editor to colour.\n"
        "use std::collections::BTreeMap;\n\n"
        "/// 一个宽字符标题 — and an emoji: 👨‍👩‍👧\n"
        "pub struct Ledger {\n"
        "    entries: BTreeMap<String, i64>,\n"
        "}\n\n"
        "impl Ledger {\n"
        "    pub fn credit(&mut self, who: &str, amount: i64) {\n"
        "        *self.entries.entry(who.to_string()).or_default() += amount;\n"
        "    }\n"
        "}\n",
        encoding="utf-8",
    )
    return home


def environment(home: Path) -> dict[str, str]:
    return {
        "TERM": "xterm-256color",
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "HOME": str(home),
        "USER": "tether",
        "LOGNAME": "tether",
        "SHELL": "/bin/sh",
        "PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/local/bin"),
        "PS1": "$ ",
        "COLUMNS": str(COLUMNS),
        "LINES": str(ROWS),
        "CLICOLOR_FORCE": "1",
        # A pager inside git would make every git recording a `less` recording.
        "GIT_PAGER": "cat",
        "GIT_CONFIG_GLOBAL": str(home / ".gitconfig"),
        "GIT_CONFIG_SYSTEM": "/dev/null",
    }


def git_fixture(home: Path) -> Path:
    """A repository with fixed authors and fixed dates, built from nothing."""
    repo = home / "repo"
    repo.mkdir()
    env = dict(os.environ)
    env.update(
        {
            "GIT_AUTHOR_NAME": "Tether Fixture",
            "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Tether Fixture",
            "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
            "GIT_AUTHOR_DATE": "2024-01-01T00:00:00+00:00",
            "GIT_COMMITTER_DATE": "2024-01-01T00:00:00+00:00",
            "GIT_CONFIG_GLOBAL": str(home / ".gitconfig"),
            "GIT_CONFIG_SYSTEM": "/dev/null",
        }
    )

    def run(*args: str) -> None:
        subprocess.run(["git", *args], cwd=repo, env=env, check=True, capture_output=True)

    run("init", "-q", "-b", "main")
    (repo / "ledger.txt").write_text("alice 10\nbob 20\n")
    run("add", "-A")
    run("commit", "-qm", "feat: a ledger with two entries")

    (repo / "ledger.txt").write_text("alice 12\nbob 20\ncarol 7\n中文 3\n")
    (repo / "README.md").write_text("# Ledger\n\nAn accounting of nothing in particular.\n")
    run("add", "-A")
    run("commit", "-qm", "feat: a third entry, and a name that is two columns wide")

    run("checkout", "-q", "-b", "side")
    (repo / "ledger.txt").write_text("alice 12\nbob 21\ncarol 7\n中文 3\n")
    run("commit", "-qam", "fix: bob was short a unit")
    run("checkout", "-q", "main")
    return repo


# Programs this machine may not have. A corpus that silently shrinks is worse
# than one that says what it could not record.
def available(program: str) -> bool:
    return shutil.which(program) is not None


def workloads(home: Path, repo: Path) -> dict[str, tuple[list[str], list[tuple[float, bytes]]]]:
    helpers = Path(__file__).resolve().parent / "corpus"
    sh = ["/bin/sh"]
    return {
        # A shell: the workload every other one starts from. Colour, a wide
        # character, a command that fails, and a prompt redrawn after each.
        "shell": (
            sh,
            [
                (0.4, b"printf 'plain \\033[31mred\\033[0m \\033[1;32mbold green\\033[0m\\n'\n"),
                (0.9, b"printf '\\033[4munderlined\\033[24m \\033[7minverse\\033[0m\\n'\n"),
                # Literal UTF-8 rather than printf escapes: `\\u` is a bashism,
                # and /bin/sh would have printed the escape back verbatim.
                (1.4, "printf '\u4e2d\u6587 wide \U0001F468\u200D\U0001F469\u200D\U0001F467 family\\n'\n".encode()),
                (1.9, b"ls -GF\n"),
                (2.4, b"false; echo \"exit $?\"\n"),
                (2.9, b"printf 'tab\\tseparated\\tcolumns\\r\\nand a carriage return\\rOVER\\n'\n"),
                (3.4, b"exit\n"),
            ],
        ),
        # An editor: the alternate screen, a status line, syntax colour, and
        # cursor motion that never redraws the whole grid.
        "vim": (
            ["vim", "sample.rs"],
            [
                (1.2, b"G"),
                (1.6, b"gg"),
                (2.0, b"/credit\r"),
                (2.5, b"ojj  // a line typed into the middle\x1b"),
                (3.2, b":set list\r"),
                (3.7, b"\x16"),  # visual block
                (3.9, b"jjl\x1b"),
                (4.4, b":q!\r"),
            ],
        ),
        # A pager: scrolling by whole screens, reverse video for a search
        # match, and the status line it rewrites in place.
        "less": (
            ["sh", "-c", "git -C repo log --color --stat | less -R"],
            [
                (1.0, b" "),
                (1.5, b" "),
                (2.0, b"/ledger\r"),
                (2.6, b"n"),
                (3.0, b"b"),
                (3.4, b"q"),
            ],
        ),
        # A git interface: colour that is generated, not typed, and a graph
        # drawn with box characters.
        "git": (
            sh,
            [
                (0.3, b"cd repo\n"),
                (0.6, b"git -c color.ui=always log --graph --decorate --oneline --all\n"),
                (1.4, b"git -c color.ui=always diff --stat HEAD~1\n"),
                (2.2, b"git -c color.ui=always diff HEAD~1\n"),
                (3.0, b"git -c color.ui=always status -sb\n"),
                (3.8, b"exit\n"),
            ],
        ),
        # tmux: a terminal inside a terminal. Its status line and its pane
        # borders are the part that breaks when damage is wrong.
        "tmux": (
            ["tmux", "-L", "tether-corpus", "-f", str(home / ".tmux.conf"), "new-session", "-s", "corpus"],
            [
                (1.2, b"printf 'left pane\\n'\n"),
                (1.8, b'\x02"'),  # C-b " — split horizontally
                (2.6, b"printf '\\033[33mlower pane\\033[0m\\n'\n"),
                (3.2, b"\x02%"),  # C-b % — split vertically
                (3.8, b"seq 1 40\n"),
                (4.6, b"\x02o"),  # C-b o — next pane
                (5.2, b"\x02c"),  # C-b c — a second window
                (6.0, b"printf 'second window\\n'\n"),
                (6.8, b"\x02&y"),  # kill window
                (7.4, b"exit\n"),
                (7.8, b"exit\n"),
                (8.2, b"exit\n"),
            ],
        ),
        # A monitoring dashboard: boxes, colour ramps and regions repainted in
        # place by cursor address. Generated rather than recorded from `top`,
        # which would put this machine's process list in a committed file.
        "dashboard": (["python3", str(helpers / "dashboard.py")], []),
        # A fuzzy finder: a candidate list redrawn under the prompt on every
        # keystroke, without the alternate screen. `fzf` is not installed
        # everywhere; this reproduces the shape it draws.
        "finder": (
            ["python3", str(helpers / "finder.py")],
            [(0.6, b"le"), (1.0, b"d"), (1.4, b"\x7f"), (1.8, b"\x1b[B"), (2.2, b"\r")],
        ),
        # A streaming agent interface: a spinner rewritten with carriage
        # returns, tokens arriving mid-word, a rewrite of lines already
        # printed, and a hyperlink.
        "agent": (["python3", str(helpers / "agent.py")], []),
    }


def main() -> int:
    CORPUS.mkdir(parents=True, exist_ok=True)
    home = sandbox()
    repo = git_fixture(home)
    env = environment(home)
    selected = set(sys.argv[1:])

    skipped: list[str] = []
    try:
        for name, (command, keys) in workloads(home, repo).items():
            if selected and name not in selected:
                continue
            program = command[0] if "/" in command[0] else command[0]
            if not available(program):
                skipped.append(f"{name}: {program} is not installed")
                continue

            os.chdir(home)
            data = record(command, keys, env)
            data = scrub(data, home)
            if not data:
                skipped.append(f"{name}: the program wrote nothing")
                continue
            (CORPUS / f"{name}.vt").write_bytes(data)
            print(f"{name:<10} {len(data):>7} bytes")
    finally:
        subprocess.run(["tmux", "-L", "tether-corpus", "kill-server"], capture_output=True)
        shutil.rmtree(home, ignore_errors=True)

    for line in skipped:
        print(f"skipped   {line}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
