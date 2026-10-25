# The Live Activity extension, sourced by build-app-ios.sh after signing.sh.
#
# A plugin's living status is drawn by the system, from this extension. The
# app only publishes the plugin's name, label and colour. A simulator signs
# it ad-hoc. A device needs a development profile for the extension's own
# bundle id; without one the app still installs and the lamp stays in the
# window. ./scripts/provision.sh asks for that profile.

# embed_live_activity <iphoneos|iphonesimulator> <app> [team]
embed_live_activity() {
  local sdk="$1" app="$2" team="${3:-}" target appex binary
  case "$sdk" in
    iphoneos) target=arm64-apple-ios26.0 ;;
    iphonesimulator) target=arm64-apple-ios26.0-simulator ;;
    *) echo "unknown sdk: $sdk" >&2; return 2 ;;
  esac
  appex="$app/PlugIns/TetherLiveActivity.appex"
  binary="$appex/TetherLiveActivity"
  rm -rf "$appex"
  mkdir -p "$appex" || return 1
  xcrun --sdk "$sdk" swiftc -parse-as-library -application-extension -O \
    -module-name TetherLiveActivity -target "$target" \
    app/Sources/TetherApp/PluginLiveAttributes.swift \
    app/Extensions/LiveActivity/PluginLiveWidget.swift \
    -o "$binary" >&2 || { rm -rf "$appex"; return 1; }

  cat > "$appex/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TetherLiveActivity</string>
    <key>CFBundleDisplayName</key><string>Tether</string>
    <key>CFBundleIdentifier</key><string>$TETHER_LIVE_ID</string>
    <key>CFBundleExecutable</key><string>TetherLiveActivity</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>MinimumOSVersion</key><string>26.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
PLIST

  if [[ "$sdk" == iphoneos ]]; then
    local profile identity
    profile=$(signing_profile ios "$team" "$TETHER_LIVE_ID" none 2>/dev/null) || {
      echo "no Live Activity profile for $team: the lamp stays in the app" >&2
      echo "(./scripts/provision.sh --team $team asks for one)" >&2
      rm -rf "$appex"
      return 0
    }
    identity=$(signing_identity "$profile") || { rm -rf "$appex"; return 1; }
    cp "$profile" "$appex/embedded.mobileprovision"
    codesign --force --sign "$identity" "$appex" >&2 || { rm -rf "$appex"; return 1; }
  else
    codesign --force --sign - "$appex" >/dev/null 2>&1 || { rm -rf "$appex"; return 1; }
  fi
}
