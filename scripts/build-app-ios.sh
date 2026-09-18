#!/usr/bin/env bash
# Assembles Tether.app for the iOS Simulator and installs it.
#
# SwiftPM builds the executable but will not produce an app bundle for iOS,
# and the simulator will not install anything else — so the bundle is put
# together here, the same way scripts/build-app.sh does it for the Mac.
#
# The device build is a different question: it needs a provisioning profile
# and a real signing identity, which belong to whoever ships it, not to this
# script (Decisions/0004).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

# A name or a udid. A name is convenient and ambiguous — this machine has two
# devices called "iPhone 17 Pro" — so a udid wins when one is given, and the
# resolved udid is printed either way so it is obvious which one was used.
DEVICE="${1:-iPhone 17 Pro}"
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
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

xcrun simctl install "$udid" "$APP"
echo "installed $APP on $DEVICE ($udid)"
echo "launch with: xcrun simctl launch $udid dev.tether.app"
