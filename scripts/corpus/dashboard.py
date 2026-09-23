#!/usr/bin/env python3
"""A monitoring dashboard, for recording into the terminal corpus.

Stands in for `top`/`btop`, which would write the recording machine's host
name and process list into a committed fixture. What matters to a terminal
engine is the *shape* of what such a program does, and that is reproduced
exactly: the alternate screen, box drawing, 256-colour ramps, and regions
repainted by cursor address rather than by redrawing the grid.

Every value comes from a fixed seed, so two runs produce the same bytes.
"""

import math
import sys

COLUMNS, ROWS = 80, 24
FRAMES = 12
GAUGES = ["cpu", "memory", "network", "disk", "swap", "load"]

out = sys.stdout


def write(text: str) -> None:
    out.write(text)


def at(row: int, column: int) -> str:
    return f"\033[{row};{column}H"


def ramp(fraction: float) -> int:
    """Green through yellow to red, in the 256-colour cube."""
    if fraction < 0.5:
        return 34 + int(fraction * 2 * 4)  # greens
    if fraction < 0.8:
        return 220
    return 196


def box(top: int, left: int, width: int, height: int, title: str) -> None:
    write(at(top, left) + "\033[38;5;240m┌" + "─" * (width - 2) + "┐")
    for row in range(1, height - 1):
        write(at(top + row, left) + "│" + " " * (width - 2) + "│")
    write(at(top + height - 1, left) + "└" + "─" * (width - 2) + "┘")
    write(at(top, left + 2) + f"\033[38;5;252m┤ {title} ├\033[0m")


def frame(tick: int) -> None:
    for index, name in enumerate(GAUGES):
        # A deterministic wave per gauge, out of phase with its neighbours.
        value = (math.sin(tick / 3.0 + index) + 1) / 2
        row = 4 + index * 2
        filled = int(value * 40)
        colour = ramp(value)
        write(at(row, 4) + f"\033[38;5;{colour}m")
        write("█" * filled + "\033[38;5;236m" + "░" * (40 - filled))
        write(f"\033[38;5;252m {value * 100:5.1f}%\033[0m")

    write(at(18, 4) + f"\033[38;5;245mframe {tick:>3} / {FRAMES}\033[0m\033[K")
    # A row of wide characters inside a box: two columns per glyph, and the
    # border must still land where the border was drawn.
    write(at(19, 4) + "\033[38;5;39m中文 メモリ 디스크\033[0m\033[K")
    out.flush()


def main() -> int:
    write("\033[?1049h\033[?25l\033[2J")
    write(at(1, 1) + "\033[1;38;5;255m  tether dashboard \033[0;38;5;245m— a recorded workload\033[0m")
    box(3, 2, COLUMNS - 3, 18, "gauges")

    for tick in range(FRAMES):
        frame(tick)

    write(at(21, 2) + "\033[7m done \033[0m")
    out.flush()
    write("\033[?25h\033[?1049l")
    out.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
