"""Push a commit to dev or master only after every workflow passed on it.

The commit gate runs every CI job this host can. The rest — Windows, on a
Mac — can only run on CI, so a commit goes to `ci/check` first, and reaches
the branch it was meant for when every workflow there is green:

    python scripts/ship.py              # HEAD to dev
    python scripts/ship.py --to master

The pre-push hook (`--pre-push`) refuses a push to dev or master of a commit
that has not passed, so nothing reaches them untried.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
PROTECTED = ("dev", "master")
POLL_SECONDS = 20
TIMEOUT_SECONDS = 90 * 60


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()


def workflows() -> list[str]:
    """Every workflow's name: each one has to pass, not just those that ran."""
    names = []
    for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
        found = re.search(r"^name:\s*(.+?)\s*$", path.read_text(encoding="utf-8"), re.M)
        names.append(found.group(1) if found else path.stem)
    return names


def runs(sha: str) -> dict[str, dict]:
    """The newest run of each workflow on this commit."""
    output = subprocess.run(
        ["gh", "run", "list", "--commit", sha, "--limit", "50",
         "--json", "workflowName,status,conclusion,databaseId,createdAt,url"],
        cwd=ROOT, check=True, capture_output=True, text=True).stdout
    newest: dict[str, dict] = {}
    for run in sorted(json.loads(output), key=lambda run: run["createdAt"]):
        newest[run["workflowName"]] = run
    return newest


def verdict(sha: str) -> tuple[bool, list[str]]:
    """Whether every workflow finished green on `sha`, and what is still open."""
    found = runs(sha)
    missing = [name for name in workflows() if found.get(name, {}).get("conclusion") != "success"]
    return not missing, missing


def pre_push(lines: list[str]) -> int:
    for line in lines:
        parts = line.split()
        if len(parts) != 4:
            continue
        _, local_sha, remote_ref, _ = parts
        branch = remote_ref.removeprefix("refs/heads/")
        if branch not in PROTECTED or set(local_sha) == {"0"}:
            continue
        green, missing = verdict(local_sha)
        if not green:
            print(f"{local_sha[:12]} has not passed {', '.join(missing)} on CI. "
                  f"Push it with: python scripts/ship.py --to {branch}", file=sys.stderr)
            return 1
    return 0


def failures(run_id: int) -> str:
    log = subprocess.run(["gh", "run", "view", str(run_id), "--log-failed"], cwd=ROOT,
                         capture_output=True, text=True).stdout
    wanted = re.compile(r"BLOCKED|error[:\[]|✘|FAILED|panicked", re.I)
    return "\n".join(line for line in log.splitlines() if wanted.search(line))[-4000:]


# One staging branch, kept: a workflow restores only caches saved on its own
# branch or the default one, so a branch per commit always ran cold.
STAGING = "ci/check"


def ship(target: str) -> int:
    sha = git("rev-parse", "HEAD")
    if not verdict(sha)[0]:
        print(f"Checking {sha[:12]} on {STAGING} …", flush=True)
        subprocess.run(["git", "push", "--force", "origin", f"{sha}:refs/heads/{STAGING}"], cwd=ROOT, check=True)
        deadline = time.monotonic() + TIMEOUT_SECONDS
        while True:
            found = runs(sha)
            done = all(found.get(name, {}).get("status") == "completed" for name in workflows())
            if done:
                break
            if time.monotonic() > deadline:
                print("Timed out waiting for CI.", file=sys.stderr)
                return 1
            time.sleep(POLL_SECONDS)
        green, missing = verdict(sha)
        if not green:
            for name in missing:
                run = found.get(name)
                print(f"\n✘ {name}: {run['url'] if run else 'no run'}", file=sys.stderr)
                if run:
                    print(failures(run["databaseId"]), file=sys.stderr)
            return 1
    print(f"{sha[:12]} passed {', '.join(workflows())}; pushing to {target}.", flush=True)
    subprocess.run(["git", "push", "origin", f"{sha}:refs/heads/{target}"], cwd=ROOT, check=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--to", default="dev", choices=PROTECTED)
    parser.add_argument("--pre-push", action="store_true", help=argparse.SUPPRESS)
    args, _ = parser.parse_known_args()
    if args.pre_push:
        return pre_push(sys.stdin.read().splitlines())
    return ship(args.to)


if __name__ == "__main__":
    sys.exit(main())
