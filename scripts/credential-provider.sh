# The credential provider extension, sourced by build-app.sh and
# build-app-ios.sh after signing.sh.
#
# It provides nothing (app/Extensions/CredentialProvider). A password manager
# offers to export to an app only when the app carries one that says it takes
# Credential Exchange, so this is what puts Tether in that list; the import
# itself is the app's. It needs the AutoFill capability, which only a team's
# profile grants: an ad-hoc build carries no extension and cannot import.
#
# Built with swiftc rather than SwiftPM: an extension is a binary whose entry
# point is Foundation's NSExtensionMain, compiled for application extensions,
# and nothing in the app package needs it.

# embed_credential_provider <macos|ios> <app> <team>
#
# Builds the extension into the app bundle and signs it, then prints the
# app's own profile, which has to grant the capability too. Fails, embedding
# nothing, when this team has no profile for either; ./scripts/provision.sh
# asks for both. Called as an `if` condition, where `set -e` does not reach,
# so every step that can fail says so itself.
embed_credential_provider() {
  local platform="$1" app="$2" team="$3" sdk target appex contents binary profile identity entitlements
  local app_profile
  app_profile=$(signing_profile "$platform" "$team" "$TETHER_BUNDLE_ID" icloud+autofill 2>/dev/null) || return 1
  profile=$(signing_profile "$platform" "$team" "$TETHER_PROVIDER_ID" autofill 2>/dev/null) || return 1
  case "$platform" in
    macos)
      sdk=macosx; target="$(uname -m)-apple-macos26.0"
      appex="$app/Contents/PlugIns/CredentialProvider.appex"; contents="$appex/Contents"
      binary="$contents/MacOS/CredentialProvider"
      ;;
    ios)
      sdk=iphoneos; target=arm64-apple-ios26.0
      appex="$app/PlugIns/CredentialProvider.appex"; contents="$appex"
      binary="$contents/CredentialProvider"
      ;;
    *) echo "unknown platform: $platform" >&2; return 2 ;;
  esac

  rm -rf "$appex"
  mkdir -p "$(dirname "$binary")" || return 1
  xcrun --sdk "$sdk" swiftc -parse-as-library -application-extension -O \
    -module-name CredentialProvider -target "$target" \
    app/Extensions/CredentialProvider/*.swift \
    -Xlinker -e -Xlinker _NSExtensionMain -o "$binary" >&2 || { rm -rf "$appex"; return 1; }

  local minimum="<key>LSMinimumSystemVersion</key><string>26.0</string>"
  [[ "$platform" == macos ]] || minimum="<key>MinimumOSVersion</key><string>26.0</string>"
  cat > "$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CredentialProvider</string>
    <key>CFBundleDisplayName</key><string>Tether</string>
    <key>CFBundleIdentifier</key><string>$TETHER_PROVIDER_ID</string>
    <key>CFBundleExecutable</key><string>CredentialProvider</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>0.0.0</string>
    <key>CFBundleVersion</key><string>0</string>
    $minimum
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.authentication-services-credential-provider-ui</string>
        <key>NSExtensionPrincipalClass</key><string>CredentialProvider.CredentialProviderViewController</string>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>ASCredentialProviderExtensionCapabilities</key>
            <dict>
                <key>SupportsCredentialExchange</key><true/>
                <key>SupportedCredentialExchangeVersions</key><array><string>1.0</string></array>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
PLIST

  local application="com.apple.application-identifier" debug="com.apple.security.get-task-allow" sandbox=""
  if [[ "$platform" == ios ]]; then
    application="application-identifier"; debug="get-task-allow"
  else
    # A Mac runs an extension only in a sandbox.
    sandbox="<key>com.apple.security.app-sandbox</key><true/>"
  fi
  entitlements=$(mktemp)
  cat > "$entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>$application</key><string>$team.$TETHER_PROVIDER_ID</string>
    <key>com.apple.developer.team-identifier</key><string>$team</string>
    <key>$AUTOFILL_ENTITLEMENT</key><true/>
    $sandbox
    <key>$debug</key><true/>
</dict>
</plist>
PLIST
  identity=$(signing_identity "$profile") || { rm -rf "$appex" "$entitlements"; return 1; }
  local embedded="$contents/embedded.provisionprofile"
  [[ "$platform" == macos ]] || embedded="$contents/embedded.mobileprovision"
  cp "$profile" "$embedded" || { rm -rf "$appex" "$entitlements"; return 1; }
  codesign --force --sign "$identity" --entitlements "$entitlements" "$appex" >&2 \
    || { rm -rf "$appex" "$entitlements"; return 1; }
  rm -f "$entitlements"
  printf '%s\n' "$app_profile"
}
