# Signing for the app bundles, sourced by build-app.sh and build-app-ios.sh.
#
# An ad-hoc signature runs, but it carries no entitlements Apple will honour,
# and CloudKit is one: without a team-signed build the host library never
# leaves the device it was typed on. So a build given a team finds that
# team's certificate and profile and signs with them; a build given none
# stays ad-hoc and says so in its sync status.
#
# Profiles come from Xcode's own store. `./scripts/provision.sh` asks Xcode
# to create or renew them; nothing here talks to Apple.

# The app's identifiers with Apple. Bundle IDs and iCloud containers are
# global, and these two are registered to the team that ships Tether; another
# team signing its own build needs identifiers of its own.
TETHER_BUNDLE_ID="${TETHER_BUNDLE_ID:-Roy-Kid.Tether}"
TETHER_CLOUD_CONTAINER="${TETHER_CLOUD_CONTAINER:-iCloud.Roy-Kid.Tether}"

PROFILE_DIRS=(
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  "$HOME/Library/MobileDevice/Provisioning Profiles"
)

# signing_profile <macos|ios> <team>
#
# The newest unexpired development profile for this app on that platform, as
# a path. Fails with a pointer to provision.sh when there is none — a profile
# that merely exists is not enough, it has to name the container, or CloudKit
# refuses the app at runtime rather than at signing.
signing_profile() {
  local platform="$1" team="$2" key extension wanted
  case "$platform" in
    macos) key=":Entitlements:com.apple.application-identifier"; extension=provisionprofile; wanted=OSX ;;
    ios) key=":Entitlements:application-identifier"; extension=mobileprovision; wanted=iOS ;;
    *) echo "unknown platform: $platform" >&2; return 2 ;;
  esac

  local now best="" best_expiry="" dir file plist expiry
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  plist=$(mktemp)
  for dir in "${PROFILE_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    for file in "$dir"/*."$extension"; do
      [[ -f "$file" ]] || continue
      security cms -D -i "$file" >"$plist" 2>/dev/null || continue
      [[ "$(/usr/libexec/PlistBuddy -c "Print $key" "$plist" 2>/dev/null)" == "$team.$TETHER_BUNDLE_ID" ]] || continue
      /usr/libexec/PlistBuddy -c "Print :Platform" "$plist" 2>/dev/null | grep -qx " *$wanted" || continue
      /usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.icloud-container-identifiers" "$plist" 2>/dev/null \
        | grep -qx " *$TETHER_CLOUD_CONTAINER" || continue
      expiry=$(plutil -extract ExpirationDate raw -o - "$plist")
      # ISO 8601 in UTC compares correctly as text.
      [[ "$expiry" > "$now" ]] || continue
      if [[ -z "$best" || "$expiry" > "$best_expiry" ]]; then
        best="$file"
        best_expiry="$expiry"
      fi
    done
  done
  rm -f "$plist"

  if [[ -z "$best" ]]; then
    echo "no $platform profile for $team.$TETHER_BUNDLE_ID with $TETHER_CLOUD_CONTAINER;" >&2
    echo "run ./scripts/provision.sh --team $team" >&2
    return 1
  fi
  printf '%s\n' "$best"
}

# signing_identity <profile>
#
# The SHA-1 of a certificate in the login keychain that the profile accepts.
# Matched through the profile rather than by name, because a person can hold
# several "Apple Development" certificates and only the ones the profile
# lists will produce a signature the device installs.
signing_identity() {
  local profile="$1" plist identities index=0 cert hash
  plist=$(mktemp)
  security cms -D -i "$profile" >"$plist"
  identities=$(security find-identity -v -p codesigning | awk '{print $2}')
  while cert=$(plutil -extract "DeveloperCertificates.$index" raw -o - "$plist" 2>/dev/null); do
    hash=$(printf '%s' "$cert" | base64 -D | shasum -a 1 | cut -c1-40 | tr '[:lower:]' '[:upper:]')
    if grep -qx "$hash" <<<"$identities"; then
      rm -f "$plist"
      printf '%s\n' "$hash"
      return 0
    fi
    index=$((index + 1))
  done
  rm -f "$plist"
  echo "no certificate in the keychain matches $profile" >&2
  return 1
}

# connected_device <name-or-identifier> <identifier|udid>
#
# A connected iPhone or iPad, found by any name devicectl knows it by.
# `identifier` is what devicectl installs to; `udid` is what xcodebuild's
# `-destination id=` and Apple's device list want.
connected_device() {
  local wanted="$1" field="$2" listing index=0 name identifier udid
  listing=$(mktemp)
  xcrun devicectl list devices --json-output "$listing" >/dev/null
  while name=$(plutil -extract "result.devices.$index.deviceProperties.name" raw -o - "$listing" 2>/dev/null); do
    identifier=$(plutil -extract "result.devices.$index.identifier" raw -o - "$listing")
    udid=$(plutil -extract "result.devices.$index.hardwareProperties.udid" raw -o - "$listing" 2>/dev/null || true)
    if [[ "$wanted" == "$name" || "$wanted" == "$identifier" || "$wanted" == "$udid" ]]; then
      rm -f "$listing"
      if [[ "$field" == udid ]]; then printf '%s\n' "$udid"; else printf '%s\n' "$identifier"; fi
      return 0
    fi
    index=$((index + 1))
  done
  rm -f "$listing"
  echo "no connected device named or identified '$wanted' (xcrun devicectl list devices)" >&2
  return 1
}

# signing_entitlements <macos|ios> <team> <output>
#
# What Xcode would sign a development build with, and no more. The CloudKit
# environment is left to the profile, which makes a development build talk to
# the development database — the one that accepts a schema as records arrive.
signing_entitlements() {
  local platform="$1" team="$2" output="$3" application debug
  case "$platform" in
    macos) application="com.apple.application-identifier"; debug="com.apple.security.get-task-allow" ;;
    ios) application="application-identifier"; debug="get-task-allow" ;;
    *) echo "unknown platform: $platform" >&2; return 2 ;;
  esac
  cat >"$output" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>$application</key><string>$team.$TETHER_BUNDLE_ID</string>
    <key>com.apple.developer.team-identifier</key><string>$team</string>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array><string>$TETHER_CLOUD_CONTAINER</string></array>
    <key>com.apple.developer.icloud-services</key>
    <array><string>CloudKit</string></array>
    <key>$debug</key><true/>
</dict>
</plist>
PLIST
}
