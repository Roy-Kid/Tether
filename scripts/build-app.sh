#!/usr/bin/env bash
# Assembles Tether.app from the app package.
#
# SwiftPM produces a bare executable; macOS needs a bundle before it will
# treat one as an application — a plain binary launched from Finder gets no
# menu bar, no Dock icon and no activation. So this is not packaging ceremony,
# it is what makes the thing double-clickable.
#
# The SDK is untouched by any of it: this script reads from app/, which is a
# consumer like any other (spec §4 — the components never name a consumer).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh

usage() {
  cat <<'EOF'
Usage: ./scripts/build-app.sh [--config debug|release] [--team <TEAMID>]

Assemble Tether.app from the app package into build/Tether.app.

Options:
  --config debug|release   build configuration (default: debug)
  --team <TEAMID>          sign with this team's development profile, which is
                           what turns on iCloud sync (or TETHER_TEAM; default:
                           ad-hoc, no iCloud)
  -h, --help               show this help
EOF
}

CONFIG=debug
TEAM="${TETHER_TEAM:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ -n "${2:-}" ]] || { echo "--config needs a value" >&2; usage >&2; exit 2; }
      CONFIG="$2"
      shift 2
      continue
      ;;
    --team) TEAM="${2:?--team needs a value}"; shift 2; continue ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done
[[ "$CONFIG" == debug || "$CONFIG" == release ]] || {
  echo "--config must be debug or release, got: $CONFIG" >&2
  usage >&2
  exit 2
}

APP="build/Tether.app"

swift build --package-path app -c "$CONFIG"
binary="$(swift build --package-path app -c "$CONFIG" --show-bin-path)/TetherApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$binary" "$APP/Contents/MacOS/TetherApp"

# AppIcon.appiconset is the source; actool is what Xcode would run, and it
# writes AppIcon.icns plus Assets.car into Resources.
partial=$(mktemp)
xcrun actool app/Assets.xcassets \
  --compile "$APP/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 26.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$partial" \
  --notices --warnings
rm -f "$partial"

# The xcframework is a static library, linked into the binary above, so there
# is nothing further to embed — that is why the artifact is a static library.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Tether</string>
    <key>CFBundleDisplayName</key><string>Tether</string>
    <key>CFBundleIdentifier</key><string>$TETHER_BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>TetherApp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.0</string>
    <key>CFBundleVersion</key><string>0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Without any signature the bundle is killed on launch on Apple Silicon, so a
# build without a team is signed ad-hoc: runnable here, nothing more. With a
# team it carries the profile and entitlements CloudKit checks for.
if [[ -n "$TEAM" ]]; then
  profile=$(signing_profile macos "$TEAM")
  identity=$(signing_identity "$profile")
  entitlements=$(mktemp)
  signing_entitlements macos "$TEAM" "$entitlements"
  cp "$profile" "$APP/Contents/embedded.provisionprofile"
  codesign --force --sign "$identity" --entitlements "$entitlements" "$APP"
  rm -f "$entitlements"
else
  codesign --force --sign - "$APP"
fi

echo "wrote $APP"
