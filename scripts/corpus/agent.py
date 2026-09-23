#!/usr/bin/env python3
"""A streaming agent interface, for recording into the terminal corpus.

§12 names this as a workload of its own, and it is unlike the others: output
arrives a few characters at a time, mid-word and mid-escape-sequence; a
spinner is rewritten in place with carriage returns; lines already printed are
rewritten by moving the cursor back up; and the result carries a hyperlink.

Deterministic — no clock, no randomness, fixed text.
"""

import sys

out = sys.stdout

PROSE = (
    "The terminal is a grid, and every cell holds one grapheme cluster — which is "
    "why 中文 takes two columns, why 👨‍👩‍👧 is one cell and not three, and why a "
    "renderer that counted bytes would draw all of them wrong.\n"
)

CODE = [
    ("\033[38;5;170m", "pub fn"),
    ("\033[0m", " "),
    ("\033[38;5;80m", "feed"),
    ("\033[0m", "(&mut self, bytes: &["),
    ("\033[38;5;170m", "u8"),
    ("\033[0m", "]) {\n    "),
    ("\033[38;5;245m", "// bytes in, damage out\n"),
    ("\033[0m", "}\n"),
]


def spinner(steps: int) -> None:
    for step in range(steps):
        frame = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"[step % 10]
        out.write(f"\r\033[38;5;39m{frame}\033[0m thinking\033[K")
        out.flush()


def stream(text: str, width: int = 7) -> None:
    """Emit in small chunks, so words and escape sequences are cut in half."""
    for start in range(0, len(text), width):
        out.write(text[start : start + width])
        out.flush()


def main() -> int:
    spinner(14)
    out.write("\r\033[38;5;83m✓\033[0m thought for a moment\033[K\n\n")

    stream(PROSE)
    out.write("\n")

    for colour, fragment in CODE:
        stream(colour + fragment)
    out.write("\n")

    # A hyperlink: OSC 8, which a terminal must consume without printing and
    # without losing the text between the two halves.
    out.write("see \033]8;;https://example.invalid/spec\033\\the specification\033]8;;\033\\ for why\n")

    # Rewriting lines already on screen — what a tool does when a step it
    # reported as running turns out to have finished.
    out.write("\033[38;5;245m  ⋯ running 3 checks\033[0m\n")
    out.write("\033[2A\r\033[38;5;83m  ✓ 3 checks passed\033[0m\033[K\n")
    out.write("\033[1B\r")
    out.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
