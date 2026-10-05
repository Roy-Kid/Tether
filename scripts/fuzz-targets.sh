#!/usr/bin/env bash
# Coverage-guided fuzzing of everything that reads remote bytes (spec §19).
#
# One command, so that what CI runs and what a person runs are the same thing.
# The default is a short budget — enough to catch a regression on every change;
# finding something new takes hours, which is what the nightly schedule is for.
#
#   ./scripts/fuzz-targets.sh                    # 60 seconds per target
#   ./scripts/fuzz-targets.sh --seconds 3600     # an hour per target
#
# Needs a nightly toolchain and cargo-fuzz:
#   rustup toolchain install nightly
#   cargo +nightly install cargo-fuzz
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/fuzz-targets.sh [--seconds N]

Coverage-guided fuzzing of everything that reads remote bytes (spec §19).
Replays known regressions first, then fuzzes each target for N seconds.

Options:
  --seconds N   budget per target (default: 60)
  -h, --help    show this help

Needs a nightly toolchain and cargo-fuzz:
  rustup toolchain install nightly
  cargo +nightly install cargo-fuzz
EOF
}

seconds=60
while [[ $# -gt 0 ]]; do
  case "$1" in
    --seconds)
      [[ -n "${2:-}" ]] || { echo "--seconds needs a value" >&2; usage >&2; exit 2; }
      seconds="$2"
      # `continue`, not the `shift` below: that one would be a third, with
      # nothing left to shift — and under `set -e` a failed shift ends the
      # script with status 1 and not a word. Every CI fuzz run died so.
      shift 2
      continue
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done
cd "$(dirname "$0")/.."

# The recorded workloads make good starting points: a fuzzer that begins from
# real terminal output reaches the interesting states in minutes rather than
# in days. (The directory's snapshots are read as seeds too. They are text,
# they parse as a stream of printable characters, and they cost nothing.)
CORPUS=crates/tether-terminal/tests/corpus

seeds_for() {
  case "$1" in
    terminal_stream|terminal_damage|terminal_links) echo "$CORPUS" ;;
    tmux_control) echo "fuzz/seeds/tmux_control" ;;
    *) echo "" ;;
  esac
}

failed=0
for target in terminal_stream terminal_damage terminal_session terminal_links tmux_control; do
  # Inputs that failed once are replayed before anything new is tried. A
  # fuzzer rediscovering a bug it already found is a fuzzer wasting its
  # budget, and the fix for a crash belongs in a test, not in a corpus.
  if [ -d "fuzz/regressions/$target" ]; then
    echo "── $target ── regressions"
    cargo +nightly fuzz run "$target" "fuzz/regressions/$target" -- -runs=0 || failed=1
  fi

  echo "── $target ── ${seconds}s"
  mkdir -p "fuzz/corpus/$target"
  # shellcheck disable=SC2046 # word splitting is how the seed directory is passed
  cargo +nightly fuzz run "$target" "fuzz/corpus/$target" $(seeds_for "$target") -- \
    -max_total_time="$seconds" -max_len=16384 -rss_limit_mb=2048 || failed=1
done

if [ "$failed" -ne 0 ]; then
  echo
  echo "A target failed. The input that did it is under fuzz/artifacts/ —" >&2
  echo "commit it as a regression, then reproduce with:" >&2
  echo "  cargo +nightly fuzz run <target> fuzz/artifacts/<target>/<input>" >&2
  exit 1
fi
