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

usage() {
  cat <<'EOF'
Usage: ./scripts/build-app.sh [--config debug|release]

Assemble Tether.app from the app package into build/Tether.app.

Options:
  --config debug|release   build configuration (default: debug)
  --signing-identity <id>  signing identity (default: ad-hoc)
  --entitlements <plist>  provisioned capabilities; requires a signing identity
  --provisioning-profile <path>  embed the matching macOS profile
  -h, --help               show this help
EOF
}

CONFIG=debug
SIGNING_IDENTITY=-
ENTITLEMENTS=
PROVISIONING_PROFILE=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ -n "${2:-}" ]] || { echo "--config needs a value" >&2; usage >&2; exit 2; }
      CONFIG="$2"
      shift 2
      continue
      ;;
    --signing-identity) SIGNING_IDENTITY="${2:?missing signing identity}"; shift 2; continue ;;
    --entitlements) ENTITLEMENTS="${2:?missing entitlements path}"; shift 2; continue ;;
    --provisioning-profile) PROVISIONING_PROFILE="${2:?missing provisioning profile}"; shift 2; continue ;;
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
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Tether</string>
    <key>CFBundleDisplayName</key><string>Tether</string>
    <key>CFBundleIdentifier</key><string>dev.tether.app</string>
    <key>CFBundleExecutable</key><string>TetherApp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.0</string>
    <key>CFBundleVersion</key><string>0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSUserNotificationsUsageDescription</key>
    <string>Nerve tells you when an agent needs you.</string>
</dict>
</plist>
PLIST

# Ad-hoc signing: without any signature the bundle is killed on launch on
# Apple Silicon. This is not distribution signing — it makes a local build
# runnable, nothing more.
signing_args=(--force --sign "$SIGNING_IDENTITY")
if [[ -n "$ENTITLEMENTS" ]]; then
  [[ "$SIGNING_IDENTITY" != - ]] || { echo "iCloud entitlements require a provisioned signing identity" >&2; exit 2; }
  signing_args+=(--entitlements "$ENTITLEMENTS")
fi
if [[ -n "$PROVISIONING_PROFILE" ]]; then
  cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
fi
codesign "${signing_args[@]}" "$APP"

echo "wrote $APP"
