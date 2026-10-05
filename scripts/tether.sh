#!/usr/bin/env bash
# Tether — single dev + verify launcher (explicit flags only).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: ./scripts/tether.sh [options]

Dev launcher and verify harness. Nothing runs unless you pass a flag.

Build:
  --build-app [--config debug|release]       assemble macOS Tether.app (default debug)
  --build-app-ios [--device <name-or-udid>]  simulator Tether.app + install
                                             (default "iPhone 17 Pro")
  --build-app-ios --phone <name-or-udid>     connected iPhone/iPad Tether.app + install
  --build-xcframework                        TetherFFI.xcframework + checked-in bindings
  --provision                                ask Xcode for this team's profiles

Signing (builds without a team are ad-hoc: they run, but have no iCloud sync):
  --team <TEAMID>         Apple developer team to sign with (or TETHER_TEAM)

Verify / test (each is standalone):
  --fuzz [N]              coverage-guided fuzz, N seconds per target (default 60)
  --verify-consumer       PATH-stripped consumer build
  --record-corpus [names…]  re-record the §12 workloads (all, or just the named ones)
  --check                 cargo clippy --workspace --all-targets -- -D warnings
  --test                  cargo test --workspace

  -h, --help              show this help

Examples:
  ./scripts/tether.sh --build-app
  ./scripts/tether.sh --build-app --config release
  ./scripts/tether.sh --provision --team ABCDE12345
  ./scripts/tether.sh --build-app-ios --phone "My iPhone" --team ABCDE12345
  ./scripts/tether.sh --fuzz 60
  ./scripts/tether.sh --check
  ./scripts/tether.sh --record-corpus shell vim
EOF
}

DO_BUILD_APP=0
DO_BUILD_APP_IOS=0
DO_PROVISION=0
DO_BUILD_XCFRAMEWORK=0
DO_FUZZ=0
DO_VERIFY_CONSUMER=0
DO_RECORD_CORPUS=0
DO_CHECK=0
DO_TEST=0

CONFIG=debug
DEVICE="iPhone 17 Pro"
PHONE=
TEAM="${TETHER_TEAM:-}"
FUZZ_SECONDS=60
CORPUS_NAMES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-app)
      DO_BUILD_APP=1
      if [[ "${2:-}" == "--config" ]]; then
        [[ -n "${3:-}" ]] || { echo "--config needs a value" >&2; usage >&2; exit 2; }
        CONFIG="$3"
        shift 2
      fi
      ;;
    --build-app-ios)
      DO_BUILD_APP_IOS=1
      if [[ "${2:-}" == "--device" || "${2:-}" == "--phone" ]]; then
        [[ -n "${3:-}" ]] || { echo "$2 needs a value" >&2; usage >&2; exit 2; }
        if [[ "$2" == "--device" ]]; then DEVICE="$3"; else PHONE="$3"; fi
        shift 2
      fi
      ;;
    --provision) DO_PROVISION=1 ;;
    --team)
      [[ -n "${2:-}" ]] || { echo "--team needs a value" >&2; usage >&2; exit 2; }
      TEAM="$2"
      shift
      ;;
    --build-xcframework) DO_BUILD_XCFRAMEWORK=1 ;;
    --fuzz)
      DO_FUZZ=1
      if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
        FUZZ_SECONDS="$2"
        shift
      fi
      ;;
    --verify-consumer) DO_VERIFY_CONSUMER=1 ;;
    --record-corpus)
      DO_RECORD_CORPUS=1
      # Workload names are positional, never flags: consume them until the
      # next option so `--record-corpus shell vim` reaches the recorder.
      while [[ $# -gt 1 && "$2" != -* ]]; do
        CORPUS_NAMES+=("$2")
        shift
      done
      ;;
    --check) DO_CHECK=1 ;;
    --test) DO_TEST=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ $DO_BUILD_APP -eq 0 && $DO_BUILD_APP_IOS -eq 0 && $DO_BUILD_XCFRAMEWORK -eq 0 && $DO_PROVISION -eq 0 \
  && $DO_FUZZ -eq 0 && $DO_VERIFY_CONSUMER -eq 0 \
  && $DO_RECORD_CORPUS -eq 0 && $DO_CHECK -eq 0 && $DO_TEST -eq 0 ]]; then
  usage
  exit 2
fi

# Profiles before the builds that sign with them.
if [[ $DO_PROVISION -eq 1 ]]; then
  echo "== provision development profiles =="
  TETHER_TEAM="$TEAM" "$ROOT/scripts/provision.sh" ${PHONE:+--phone "$PHONE"}
fi

if [[ $DO_BUILD_APP -eq 1 ]]; then
  if [[ "$CONFIG" != debug && "$CONFIG" != release ]]; then
    echo "--config must be debug or release, got: $CONFIG" >&2
    usage >&2
    exit 2
  fi
  echo "== build macOS Tether.app ($CONFIG) =="
  TETHER_TEAM="$TEAM" "$ROOT/scripts/build-app.sh" --config "$CONFIG"
fi

if [[ $DO_BUILD_APP_IOS -eq 1 ]]; then
  if [[ -n "$PHONE" ]]; then
    echo "== build + install device Tether.app =="
    TETHER_TEAM="$TEAM" "$ROOT/scripts/build-app-ios.sh" --phone "$PHONE"
  else
    echo "== build + install simulator Tether.app =="
    TETHER_TEAM="$TEAM" "$ROOT/scripts/build-app-ios.sh" --device "$DEVICE"
  fi
fi

if [[ $DO_BUILD_XCFRAMEWORK -eq 1 ]]; then
  echo "== build TetherFFI.xcframework + bindings =="
  "$ROOT/scripts/build-xcframework.sh"
fi

if [[ $DO_FUZZ -eq 1 ]]; then
  echo "== fuzz ($FUZZ_SECONDS s per target) =="
  "$ROOT/scripts/fuzz-targets.sh" --seconds "$FUZZ_SECONDS"
fi

if [[ $DO_VERIFY_CONSUMER -eq 1 ]]; then
  echo "== PATH-stripped consumer build =="
  "$ROOT/scripts/verify-consumer-build.sh"
fi

if [[ $DO_RECORD_CORPUS -eq 1 ]]; then
  echo "== record §12 corpus =="
  "$ROOT/scripts/record-corpus.py" ${CORPUS_NAMES[@]+"${CORPUS_NAMES[@]}"}
fi

if [[ $DO_CHECK -eq 1 ]]; then
  echo "== cargo clippy =="
  cargo clippy --workspace --all-targets -- -D warnings
fi

if [[ $DO_TEST -eq 1 ]]; then
  echo "== cargo test =="
  cargo test --workspace
fi

echo "done"
