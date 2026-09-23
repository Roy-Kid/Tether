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

CONFIG="${1:-debug}"
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
# is nothing further to embed — the reason Decisions/0004 chose that shape.
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
codesign --force --sign - "$APP" >/dev/null 2>&1 || {
  echo "warning: could not sign $APP; it may refuse to launch" >&2
}

echo "wrote $APP"
