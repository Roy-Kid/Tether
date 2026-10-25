#!/usr/bin/env bash
# Creates or renews the development profiles the signed builds use.
#
# The app is assembled by scripts rather than by an Xcode project, and only
# Xcode's automatic signing knows how to ask Apple for a profile with the
# account a person is already signed into. So this writes a throwaway project
# that declares the same identifiers and capabilities, and lets Xcode register
# them — the bundle ID, the iCloud container, the credential provider
# extension and its AutoFill capability, this Mac, a phone if one is named —
# and download the profiles into its own store, where signing.sh finds them.
# Nothing of the project is kept.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh

usage() {
  cat <<'EOF'
Usage: ./scripts/provision.sh --team <TEAMID> [--phone <name>]

Ask Xcode to create or renew the development profiles for Tether.

Options:
  --team <TEAMID>   the Apple developer team to sign with (or TETHER_TEAM)
  --phone <name>    also register this connected iPhone or iPad
  -h, --help        show this help

Needs Xcode signed into the team's account and xcodegen (brew install xcodegen).
EOF
}

TEAM="${TETHER_TEAM:-}"
PHONE=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --team) TEAM="${2:?--team needs a value}"; shift 2 ;;
    --phone) PHONE="${2:?--phone needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$TEAM" ]] || { echo "--team is required" >&2; usage >&2; exit 2; }
command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src" "$work/provider" "$work/live"
echo 'print("provision")' >"$work/src/main.swift"
cp app/Extensions/CredentialProvider/*.swift "$work/provider/"
cp app/Sources/TetherApp/PluginLiveAttributes.swift app/Extensions/LiveActivity/PluginLiveWidget.swift "$work/live/"
cat >"$work/live/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
EOF
cat >"$work/provider/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>0.0.0</string>
    <key>CFBundleVersion</key><string>0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.authentication-services-credential-provider-ui</string>
        <key>NSExtensionPrincipalClass</key><string>$(PRODUCT_MODULE_NAME).CredentialProviderViewController</string>
    </dict>
</dict>
</plist>
EOF

target() {
  # A Mac runs an extension only in a sandbox; a phone runs every one in one.
  local sandbox= live_dep= live_target=
  [[ "$2" != macOS ]] || sandbox="com.apple.security.app-sandbox: true"
  if [[ "$2" == iOS ]]; then
    live_dep="
      - target: LiveActivity$1"
    live_target="
  LiveActivity$1:
    type: app-extension
    platform: iOS
    deploymentTarget: \"26.0\"
    sources: [live]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $TETHER_LIVE_ID
        INFOPLIST_FILE: live/Info.plist
        GENERATE_INFOPLIST_FILE: NO
"
  fi
  cat <<EOF
  Tether$1:
    type: application
    platform: $2
    deploymentTarget: "26.0"
    sources: [src]
    dependencies:
      - target: Provider$1$live_dep
    entitlements:
      path: $1.entitlements
      properties:
        com.apple.developer.icloud-container-identifiers: [$TETHER_CLOUD_CONTAINER]
        com.apple.developer.icloud-services: [CloudKit]
        $AUTOFILL_ENTITLEMENT: true
  Provider$1:
    type: app-extension
    platform: $2
    deploymentTarget: "26.0"
    sources: [provider]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $TETHER_PROVIDER_ID
        INFOPLIST_FILE: provider/Info.plist
        GENERATE_INFOPLIST_FILE: NO
    entitlements:
      path: Provider$1.entitlements
      properties:
        $AUTOFILL_ENTITLEMENT: true
        $sandbox
$live_target
EOF
}

{
  cat <<EOF
name: TetherProvision
settings:
  base:
    DEVELOPMENT_TEAM: $TEAM
    CODE_SIGN_STYLE: Automatic
    PRODUCT_BUNDLE_IDENTIFIER: $TETHER_BUNDLE_ID
    GENERATE_INFOPLIST_FILE: YES
targets:
EOF
  target Mac macOS
  target Phone iOS
} >"$work/project.yml"

(cd "$work" && xcodegen generate --quiet)

# A concrete Mac rather than a generic destination: only then does Xcode
# register this machine, and a Mac development profile lists the Macs it runs on.
provision() {
  echo "== $1 =="
  xcodebuild -project "$work/TetherProvision.xcodeproj" -scheme "$1" -destination "$2" \
    -derivedDataPath "$work/DerivedData" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    build >"$work/$1.log" 2>&1 || {
    grep -E "error:" "$work/$1.log" >&2 || tail -20 "$work/$1.log" >&2
    exit 1
  }
}

provision TetherMac "platform=macOS,arch=$(uname -m)"
if [[ -n "$PHONE" ]]; then
  phone=$(connected_device "$PHONE" udid)
  provision TetherPhone "platform=iOS,id=$phone"
else
  provision TetherPhone "generic/platform=iOS"
fi

echo "macOS: $(signing_profile macos "$TEAM" "$TETHER_BUNDLE_ID" icloud+autofill)"
echo "       $(signing_profile macos "$TEAM" "$TETHER_PROVIDER_ID" autofill)"
echo "iOS:   $(signing_profile ios "$TEAM" "$TETHER_BUNDLE_ID" icloud+autofill)"
echo "       $(signing_profile ios "$TEAM" "$TETHER_PROVIDER_ID" autofill)"
