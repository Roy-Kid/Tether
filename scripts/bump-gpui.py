#!/usr/bin/env python3
"""Move GPUI to Zed's latest stable release (Decisions/0022).

GPUI comes from Zed's repository at a release tag, named once for `gpui`
and once for `gpui_platform` in the workspace manifest. This finds Zed's
latest stable release, moves both tags to it and updates the lockfile.

`--check` changes nothing and fails when a newer release is out. The
`gpui-release` gate job runs that nightly.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "Cargo.toml"
RELEASES = "https://api.github.com/repos/zed-industries/zed/releases/latest"
# `gpui = { git = "https://github.com/zed-industries/zed", tag = "v1.27.0", ... }`
PINNED = re.compile(
    r'^(gpui(?:_platform)? = \{ git = "https://github\.com/zed-industries/zed", tag = ")'
    r'(v\d+\.\d+\.\d+)(")',
    re.MULTILINE,
)
STABLE = re.compile(r"v\d+\.\d+\.\d+")


def pinned(manifest: str) -> str:
    """The one tag both GPUI lines name."""
    tags = {found.group(2) for found in PINNED.finditer(manifest)}
    if len(PINNED.findall(manifest)) != 2 or len(tags) != 1:
        raise RuntimeError("Cargo.toml must name gpui and gpui_platform at one Zed tag")
    return tags.pop()


def retagged(manifest: str, tag: str) -> str:
    if not STABLE.fullmatch(tag):
        raise RuntimeError(f"{tag!r} is not a stable Zed release tag")
    return PINNED.sub(lambda found: f"{found.group(1)}{tag}{found.group(3)}", manifest)


def version(tag: str) -> tuple[int, ...]:
    return tuple(int(part) for part in tag.removeprefix("v").split("."))


def latest() -> str:
    """Zed's latest stable release. `/releases/latest` skips pre-releases."""
    request = urllib.request.Request(RELEASES, headers={"Accept": "application/vnd.github+json"})
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=30) as response:
        tag = json.load(response).get("tag_name", "")
    if not STABLE.fullmatch(tag):
        raise RuntimeError(f"Zed's latest release has tag {tag!r}, not a stable version")
    return tag


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail when a newer release is out")
    args = parser.parse_args()
    manifest = MANIFEST.read_text(encoding="utf-8")
    current, newest = pinned(manifest), latest()
    if version(newest) <= version(current):
        print(f"GPUI is at Zed {current}, the latest stable release.")
        return 0
    if args.check:
        print(f"Zed {newest} is out; GPUI is at {current}. Run scripts/bump-gpui.py.", file=sys.stderr)
        return 1
    MANIFEST.write_text(retagged(manifest, newest), encoding="utf-8")
    subprocess.run(["cargo", "update", "-p", "gpui"], cwd=ROOT, check=True)
    print(f"GPUI moved from Zed {current} to {newest}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
