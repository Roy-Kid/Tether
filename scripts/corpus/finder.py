#!/usr/bin/env python3
"""A fuzzy finder, for recording into the terminal corpus.

Stands in for `fzf`, which is not installed everywhere. The behaviour that
matters to a terminal engine is the one this reproduces: a candidate list
drawn *below the prompt on the main screen*, not on the alternate screen, and
redrawn on every keystroke by moving the cursor up, erasing to the end of each
line, and drawing again. Nothing else in the corpus exercises that path.
"""

import sys
import termios
import tty

CANDIDATES = [
    "crates/tether-terminal/src/terminal.rs",
    "crates/tether-terminal/src/screen.rs",
    "crates/tether-ssh/src/session.rs",
    "crates/tether-core/src/session.rs",
    "crates/tether-ffi/src/lib.rs",
    "app/Sources/TetherApp/SessionModel.swift",
    "中文/ledger.rs",
]
VISIBLE = 5


def matches(query: str) -> list[str]:
    """Subsequence matching, the way a fuzzy finder does it."""
    found = []
    for candidate in CANDIDATES:
        position = 0
        for character in query.lower():
            position = candidate.lower().find(character, position)
            if position < 0:
                break
            position += 1
        else:
            found.append(candidate)
    return found


def draw(query: str, selected: int, drawn: int) -> int:
    out = sys.stdout
    if drawn:
        out.write(f"\033[{drawn}A")  # back to the prompt line
    out.write("\r\033[38;5;39m>\033[0m " + query + "\033[K\n")

    rows = matches(query)[:VISIBLE]
    for index, row in enumerate(rows):
        marker = "\033[7m" if index == selected else ""
        out.write(f"{marker}  {row}\033[0m\033[K\n")
    out.write(f"\033[38;5;245m  {len(rows)}/{len(CANDIDATES)}\033[0m\033[K")
    out.flush()
    return len(rows) + 1


def main() -> int:
    query, selected, drawn = "", 0, 0
    settings = termios.tcgetattr(sys.stdin)
    tty.setraw(sys.stdin)
    try:
        drawn = draw(query, selected, 0)
        while True:
            key = sys.stdin.buffer.read(1)
            if key in (b"\r", b"\n", b"\x03", b""):
                break
            if key == b"\x7f":
                query = query[:-1]
            elif key == b"\x1b":
                sequence = sys.stdin.buffer.read(2)
                if sequence == b"[B":
                    selected += 1
                elif sequence == b"[A":
                    selected = max(0, selected - 1)
            else:
                query += key.decode("utf-8", "replace")
            selected = min(selected, max(0, len(matches(query)) - 1))
            drawn = draw(query, selected, drawn)
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, settings)

    chosen = matches(query)[selected : selected + 1]
    sys.stdout.write("\r\n" + (chosen[0] if chosen else "(nothing)") + "\r\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
