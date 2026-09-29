#!/usr/bin/env bash
# Assembles Tether.app for iOS and installs it: on a simulator by default, on
# a connected iPhone or iPad with --phone.
#
# SwiftPM builds the executable but will not produce an app bundle for iOS,
# and neither a simulator nor a device will install anything else — so the
# bundle is put together here, the same way ./scripts/build-app.sh does it
# for the Mac.
#
# A device only installs what a team signed, so --phone needs --team, and
# only a device build syncs through iCloud. A simulator runs ad-hoc: it
# rejects restricted entitlements in an ad-hoc signature, and the simulator's
# CloudKit does not take them from the binary's entitlement sections either
# (tried: __entitlements and __ents_der), so it stays a local-only build.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
source scripts/signing.sh

usage() {
  cat <<'EOF'
Usage: ./scripts/build-app-ios.sh [--device <name-or-udid> | --phone <name-or-udid>] [--team <TEAMID>]

Assemble Tether.app for iOS and install it.

Options:
  --device <name-or-udid>  simulator to target (default: "iPhone 17 Pro")
  --phone <name-or-udid>   connected iPhone or iPad to target; needs --team
  --team <TEAMID>          sign the --phone build with this team's development
                           profile, which is what turns on iCloud sync
                           (or TETHER_TEAM); simulators never sync
  -h, --help               show this help
EOF
}

DEVICE="iPhone 17 Pro"
PHONE=
TEAM="${TETHER_TEAM:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      [[ -n "${2:-}" ]] || { echo "--device needs a value" >&2; usage >&2; exit 2; }
      DEVICE="$2"
      shift 2
      continue
      ;;
    --phone) PHONE="${2:?--phone needs a value}"; shift 2; continue ;;
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
[[ -z "$PHONE" || -n "$TEAM" ]] || { echo "--phone needs --team: a device only installs a team-signed app" >&2; exit 2; }

DERIVED=build/ios
APP="$ROOT/$DERIVED/Tether.app"

if [[ -n "$PHONE" ]]; then
  udid=$(connected_device "$PHONE" identifier)
  platform=iphoneos
  destination="generic/platform=iOS"
else
  # The udid first, and only then boot it. Several simulators can share a
  # name — this machine has two "iPhone 17 Pro" and an "iPhone 17 Pro
  # (watch)" — so booting by name and installing by a separately-resolved
  # udid can reach two different simulators.
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
  xcrun simctl boot "$udid" 2>/dev/null || true
  # `boot` returns before the device is usable, and `install` on a booting
  # device fails with a state error rather than waiting.
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  platform=iphonesimulator
  destination="platform=iOS Simulator,id=$udid"
fi
echo "using $udid"

# The package lives in app/, so that is where xcodebuild has to run.
(cd app && xcodebuild -scheme TetherApp \
  -destination "$destination" \
  -derivedDataPath "$ROOT/$DERIVED/DerivedData" \
  ONLY_ACTIVE_ARCH=YES \
  build >/dev/null)

binary="$ROOT/$DERIVED/DerivedData/Build/Products/Debug-$platform/TetherApp"
[ -f "$binary" ] || { echo "no executable at $binary" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP"
cp "$binary" "$APP/TetherApp"

# Same catalog as the Mac bundle. iOS wants the 60pt/76pt PNGs plus Assets.car.
partial=$(mktemp)
xcrun actool app/Assets.xcassets \
  --compile "$APP" \
  --platform "$platform" \
  --minimum-deployment-target 26.0 \
  --app-icon AppIcon \
  --target-device iphone \
  --target-device ipad \
  --output-partial-info-plist "$partial" \
  --notices --warnings
rm -f "$partial"

# iOS has no public API for an app to read its own entitlements, so the
# container is also named here: HostCloudSync only touches CloudKit when the
# bundle says it was signed for it, because CloudKit without the entitlement
# is an exception, not an error.
cloud=
[[ -z "$PHONE" ]] || cloud="<key>TetherCloudContainer</key><string>$TETHER_CLOUD_CONTAINER</string>"

# A flat bundle, not Contents/MacOS: iOS puts the executable at the top.
cat > "$APP/Info.plist" <<PLIST
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
    $cloud
</dict>
</plist>
PLIST

if [[ -n "$PHONE" ]]; then
  profile=$(signing_profile ios "$TEAM")
  entitlements=$(mktemp)
  signing_entitlements ios "$TEAM" "$entitlements"
  identity=$(signing_identity "$profile")
  cp "$profile" "$APP/embedded.mobileprovision"
  codesign --force --sign "$identity" --entitlements "$entitlements" "$APP"
  rm -f "$entitlements"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

if [[ -n "$PHONE" ]]; then
  xcrun devicectl device install app --device "$udid" "$APP" >/dev/null
  echo "installed $APP on $PHONE ($udid)"
  echo "launch with: xcrun devicectl device process launch --device $udid $TETHER_BUNDLE_ID"
else
  xcrun simctl install "$udid" "$APP"
  echo "installed $APP on $DEVICE ($udid)"
  echo "launch with: xcrun simctl launch $udid $TETHER_BUNDLE_ID"
fi
