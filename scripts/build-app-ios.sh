#!/usr/bin/env bash
# Assembles Tether.app for the iOS Simulator and installs it.
#
# SwiftPM builds the executable but will not produce an app bundle for iOS,
# and the simulator will not install anything else — so the bundle is put
# together here, the same way ./scripts/build-app.sh does it for the Mac.
#
# The device build is a different question: it needs a provisioning profile
# and a real signing identity, which belong to whoever ships it, not to this
# script.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

usage() {
  cat <<'EOF'
Usage: ./scripts/build-app-ios.sh [--device <name-or-udid>]

Assemble Tether.app for the iOS Simulator and install it.

Options:
  --device <name-or-udid>  simulator to target (default: "iPhone 17 Pro")
  -h, --help               show this help
EOF
}

DEVICE="iPhone 17 Pro"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      [[ -n "${2:-}" ]] || { echo "--device needs a value" >&2; usage >&2; exit 2; }
      DEVICE="$2"
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

# A name or a udid. A name is convenient and ambiguous — this machine has two
# devices called "iPhone 17 Pro" — so a udid wins when one is given, and the
# resolved udid is printed either way so it is obvious which one was used.
DERIVED=build/ios
APP="$ROOT/$DERIVED/Tether.app"

# The udid first, and only then boot it. Several devices can share a name —
# this machine has two "iPhone 17 Pro" and an "iPhone 17 Pro (watch)" — so
# booting by name and installing by a separately-resolved udid can reach two
# different simulators.
if [[ "$DEVICE" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
  udid="$DEVICE"
else
  matches=$(xcrun simctl list devices available \
    | grep -E "^ +$DEVICE \(" \
    | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
  count=$(printf '%s\n' "$matches" | grep -c . || true)
  [ "$count" -gt 0 ] || { echo "no available simulator named exactly '$DEVICE'" >&2; exit 1; }
  if [ "$count" -gt 1 ]; then
    echo "'$DEVICE' matches $count devices; pass a udid instead:" >&2
    printf '%s\n' "$matches" | sed 's/^/  /' >&2
    exit 1
  fi
  udid="$matches"
fi
echo "using $udid"

xcrun simctl boot "$udid" 2>/dev/null || true
# `boot` returns before the device is usable, and `install` on a booting
# device fails with a state error rather than waiting.
xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true

# The package lives in app/, so that is where xcodebuild has to run.
(cd app && xcodebuild -scheme TetherApp \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$ROOT/$DERIVED/DerivedData" \
  ONLY_ACTIVE_ARCH=YES \
  build >/dev/null)

binary="$ROOT/$DERIVED/DerivedData/Build/Products/Debug-iphonesimulator/TetherApp"
[ -f "$binary" ] || { echo "no executable at $binary" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP"
cp "$binary" "$APP/TetherApp"

# Same catalog as the Mac bundle. iOS wants the 60pt/76pt PNGs plus Assets.car.
partial=$(mktemp)
xcrun actool app/Assets.xcassets \
  --compile "$APP" \
  --platform iphonesimulator \
  --minimum-deployment-target 26.0 \
  --app-icon AppIcon \
  --target-device iphone \
  --target-device ipad \
  --output-partial-info-plist "$partial" \
  --notices --warnings
rm -f "$partial"

# A flat bundle, not Contents/MacOS: iOS puts the executable at the top.
cat > "$APP/Info.plist" <<'PLIST'
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
    <key>CFBundleIcons</key>
    <dict>
        <key>CFBundlePrimaryIcon</key>
        <dict>
            <key>CFBundleIconFiles</key>
            <array>
                <string>AppIcon60x60</string>
            </array>
            <key>CFBundleIconName</key>
            <string>AppIcon</string>
        </dict>
    </dict>
    <key>CFBundleIcons~ipad</key>
    <dict>
        <key>CFBundlePrimaryIcon</key>
        <dict>
            <key>CFBundleIconFiles</key>
            <array>
                <string>AppIcon60x60</string>
                <string>AppIcon76x76</string>
            </array>
            <key>CFBundleIconName</key>
            <string>AppIcon</string>
        </dict>
    </dict>
    <key>LSRequiresIPhoneOS</key><true/>
    <key>MinimumOSVersion</key><string>26.0</string>
    <key>UILaunchScreen</key><dict/>
    <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>UISupportedInterfaceOrientations~ipad</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationPortraitUpsideDown</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

xcrun simctl install "$udid" "$APP"
echo "installed $APP on $DEVICE ($udid)"
echo "launch with: xcrun simctl launch $udid dev.tether.app"
