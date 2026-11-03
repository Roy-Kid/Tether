"""Install the repository-local commit gate using this Python interpreter."""
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
subprocess.run([sys.executable, "-m", "pip", "install", "--disable-pip-version-check",
                "--target", str(root / ".check-deps"), "--requirement",
                str(root / "scripts/check-requirements.txt")], cwd=root, check=True)
subprocess.run(["git", "config", "--local", "core.hooksPath", ".githooks"], cwd=root, check=True)
subprocess.run(["git", "config", "--local", "tether.python", sys.executable], cwd=root, check=True)
for hook in ("pre-commit", "pre-push"):
    (root / ".githooks" / hook).chmod(0o755)
print("Installed the commit gate and the pre-push check for this clone.")
