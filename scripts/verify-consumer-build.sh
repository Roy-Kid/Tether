#!/usr/bin/env bash
# Proves the claim the spec makes in §21: a Swift consumer builds Tether with
# no Rust toolchain, no CMake and no network.
#
# The claim is only worth something if it is checked the way a consumer would
# hit it — by removing those tools from PATH, not by believing the Package.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: ./scripts/verify-consumer-build.sh

Prove a Swift consumer builds Tether with no Rust toolchain, no CMake and no
network: strip cargo/rustc/cmake from PATH, build and test the Swift package,
then type-check that generated symbols do not leak through the façade.

Options:
  -h, --help   show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# Strip every PATH entry that carries cargo, rustc or cmake. This machine has
# had more than one cmake installed at a time, so filter by content, not by a
# remembered prefix.
clean=""
IFS=':' read -ra entries <<< "$PATH"
for dir in "${entries[@]}"; do
  [ -d "$dir" ] || continue
  if [ -x "$dir/cargo" ] || [ -x "$dir/rustc" ] || [ -x "$dir/cmake" ]; then
    echo "  excluding $dir"
    continue
  fi
  clean="${clean:+$clean:}$dir"
done

export PATH="$clean"
for tool in cargo rustc cmake; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool still reachable at $(command -v "$tool")" >&2
    exit 1
  fi
done
echo "  cargo, rustc and cmake are all unreachable"

cd swift
swift build --disable-automatic-resolution
swift test --disable-automatic-resolution

# The façade is only a boundary if generated symbols really are unreachable
# through it. Check by type-checking against the built module rather than by
# reading the source — `-parse` would pass on anything syntactically valid.
bin=$(swift build --disable-automatic-resolution --show-bin-path)
flags=(-I "$bin" -Xcc -fmodule-map-file="$bin/include/module.modulemap" -Xcc -I"$bin/include")
probe=$(mktemp -d)

# CancellationToken is an internal mechanism; a consumer that
# can name it is a consumer that can be told to manage it.
cat > "$probe/leak.swift" <<'LEAK'
import Tether
let token = CancellationToken()
LEAK
if xcrun swiftc -swift-version 6 -typecheck "${flags[@]}" "$probe/leak.swift" 2>/dev/null; then
  echo "FAIL: generated symbols leak through the Tether module" >&2
  exit 1
fi
echo "  generated symbols are not reachable through Tether"

# The same file must compile once it imports the generated module directly, or
# the result above would be true for the wrong reason — a broken include path
# fails every type-check, including the one we want to fail.
printf 'import Tether\nimport TetherFFIBindings\nlet token = CancellationToken()\n' \
  > "$probe/control.swift"
if ! xcrun swiftc -swift-version 5 -typecheck "${flags[@]}" "$probe/control.swift" 2>/dev/null; then
  echo "FAIL: the leak check never reached the modules, so it proves nothing" >&2
  exit 1
fi
echo "  ...and the control compiles, so that result means what it says"
rm -rf "$probe"
