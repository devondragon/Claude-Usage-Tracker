#!/bin/bash
# Build a signed Release of the current checkout and install it as the
# day-to-day app in /Applications, replacing whatever copy is there.
#
#   scripts/install-local.sh            # build, install, relaunch
#   scripts/install-local.sh --no-build # reinstall the last build
#   scripts/install-local.sh --ad-hoc   # build with ad-hoc signing
#
# Signing uses the project's Release settings (Developer ID team NLLX25D2J2),
# so profile secrets stay in the login keychain across reinstalls. Use
# --ad-hoc on a machine without that certificate: the app then keeps profile
# secrets in the plaintext profiles_v3 plist (it only uses the login keychain
# when the signature has a team ID, so a self-signed certificate behaves the
# same way).

set -euo pipefail

BUNDLE_ID="com.devondragon.ClaudeUsage"
APP_NAME="Claude Usage.app"
DEST="/Applications/$APP_NAME"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILT="$REPO_ROOT/build/Build/Products/Release/$APP_NAME"

cd "$REPO_ROOT"

do_build=1
signing=()
for arg in "$@"; do
    case "$arg" in
        --no-build) do_build=0 ;;
        --ad-hoc) signing=(CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="") ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [[ $do_build == 1 ]]; then
    echo "==> Building Release ($(git rev-parse --short HEAD) on $(git branch --show-current))${signing:+, ad-hoc signed}"
    xcodebuild build -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
        -configuration Release -derivedDataPath build -quiet ${signing[@]+"${signing[@]}"}
fi

[[ -d "$BUILT" ]] || { echo "No build at $BUILT" >&2; exit 1; }

actual_id=$(/usr/bin/defaults read "$BUILT/Contents/Info.plist" CFBundleIdentifier)
[[ "$actual_id" == "$BUNDLE_ID" ]] || { echo "Built bundle ID is $actual_id, expected $BUNDLE_ID" >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$BUILT"

# Quit every running copy of this app (any path), so the bundle isn't
# replaced under a live process.
if /usr/bin/pgrep -f "Claude Usage.app/Contents/MacOS/Claude Usage" >/dev/null; then
    echo "==> Quitting running app"
    /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in {1..20}; do
        /usr/bin/pgrep -f "Claude Usage.app/Contents/MacOS/Claude Usage" >/dev/null || break
        sleep 0.5
    done
    /usr/bin/pkill -f "Claude Usage.app/Contents/MacOS/Claude Usage" || true
fi

# Refuse to overwrite a different app (such as the upstream build) by accident.
if [[ -d "$DEST" ]]; then
    existing_id=$(/usr/bin/defaults read "$DEST/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "?")
    if [[ "$existing_id" != "$BUNDLE_ID" ]]; then
        echo "$DEST has bundle ID $existing_id. Move it to the Trash first." >&2
        exit 1
    fi
    /bin/rm -rf "$DEST"
fi

echo "==> Installing to $DEST"
/usr/bin/ditto "$BUILT" "$DEST"
/usr/bin/codesign --verify --deep --strict "$DEST"

version=$(/usr/bin/defaults read "$DEST/Contents/Info.plist" CFBundleShortVersionString)
build=$(/usr/bin/defaults read "$DEST/Contents/Info.plist" CFBundleVersion)
echo "==> Installed $version ($build), launching"
/usr/bin/open "$DEST"
