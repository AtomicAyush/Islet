#!/bin/bash
# Build Islet and install it to /Applications.
#
# The app is signed with a real Apple Development certificate rather than ad-hoc.
# macOS records Bluetooth, Calendar and Accessibility permission against the code
# signature, and an ad-hoc signature gets a fresh hash on every build — so each
# rebuild would look like a new app and every permission would be asked for again.
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# Prefer a real identity; fall back to ad-hoc so the script still works without one.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Apple Development" | head -1 | awk '{print $2}')
if [ -z "$IDENTITY" ]; then
    echo "No Apple Development certificate found — signing ad-hoc."
    echo "macOS will ask for permissions again after each rebuild."
    IDENTITY="-"
fi

echo "Building…"
xcodebuild -project Islet.xcodeproj -scheme Islet -configuration Release build \
    -quiet CODE_SIGNING_ALLOWED=NO

APP=$(xcodebuild -project Islet.xcodeproj -scheme Islet -configuration Release \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')/Islet.app

echo "Signing with ${IDENTITY}…"
# The adapter framework first: /usr/bin/perl loads it, not Islet, so it is signed as
# its own bundle rather than swept up by --deep.
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/MediaRemoteAdapter.framework"
codesign --force --sign "$IDENTITY" "$APP"

pkill -x Islet 2>/dev/null || true
sleep 1
rm -rf /Applications/Islet.app
cp -R "$APP" /Applications/

echo "Launching…"
open /Applications/Islet.app
codesign -dv --verbose=2 /Applications/Islet.app 2>&1 | grep -E "Authority|Signature|TeamIdentifier" || true
