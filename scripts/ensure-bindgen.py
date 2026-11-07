"""Ensure the pinned C# binding generator is on PATH, even after a cache hit."""
import re
import shutil
import subprocess
import sys

VERSION = "0.11.0+v0.31.0"
TAG = "v0.11.0+v0.31.0"
REPOSITORY = "https://github.com/NordSecurity/uniffi-bindgen-cs"


def installed_version():
    name = "uniffi-bindgen-cs.exe" if sys.platform == "win32" else "uniffi-bindgen-cs"
    executable = shutil.which(name)
    if executable is None:
        return None
    result = subprocess.run([executable, "--version"], check=True, capture_output=True, text=True)
    # At pinned commit e10ce410eb3a10cc19c7928b93ea8d84e038c034, bindgen/src/lib.rs
    # sets clap's name to "uniffi-bindgen" and version to crate_version!().
    # bindgen/Cargo.toml supplies 0.11.0+v0.31.0 (without the tag's leading v).
    match = re.fullmatch(r"uniffi-bindgen ([0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.+-]+)?)", result.stdout.strip())
    if match is None:
        raise RuntimeError(f"Cannot identify {executable} version: {result.stdout!r}")
    return match.group(1)


def ensure_bindgen():
    version = installed_version()
    if version == VERSION:
        return
    command = ["cargo", "install", "--locked", "uniffi-bindgen-cs",
               "--git", REPOSITORY, "--tag", TAG]
    if version is not None:
        command.append("--force")
    subprocess.run(command, check=True)
    # Also catches a different executable shadowing Cargo's installation on PATH.
    actual = installed_version()
    if actual != VERSION:
        raise RuntimeError(f"Expected uniffi-bindgen-cs {VERSION} after installation, found {actual!r}")


def main():
    try:
        ensure_bindgen()
    except subprocess.CalledProcessError as error:
        print(f"Cannot ensure uniffi-bindgen-cs: {error}", file=sys.stderr)
        if error.stderr:
            print(error.stderr, file=sys.stderr)
        return error.returncode
    except (OSError, RuntimeError) as error:
        print(f"Cannot ensure uniffi-bindgen-cs: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
