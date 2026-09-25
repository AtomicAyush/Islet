#!/bin/bash
# Compiles the vendored MediaRemote adapter into a framework and copies it, with its
# Perl entry point, into the app's Resources. Run from an Xcode build phase, or by hand
# with an output directory as the only argument.
#
# The framework is never linked into Islet. /usr/bin/perl loads it at runtime, because
# perl is one of the Apple processes MediaRemote still answers on macOS 15.4 and later.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Vendor/mediaremote-adapter"
OUT="${1:-$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH}"
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
MIN="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

FW="$OUT/MediaRemoteAdapter.framework"
BIN="$FW/Versions/A/MediaRemoteAdapter"

# Skip the compile when nothing in the vendored tree is newer than the built binary.
if [ -f "$BIN" ] && [ -z "$(find "$SRC" -newer "$BIN" -type f | head -1)" ]; then
    cp "$SRC/bin/mediaremote-adapter.pl" "$OUT/"
    exit 0
fi

rm -rf "$FW"
mkdir -p "$FW/Versions/A/Resources"

ARCHS_FLAGS=()
for arch in ${ARCHS:-arm64 x86_64}; do ARCHS_FLAGS+=(-arch "$arch"); done

xcrun clang -dynamiclib -fobjc-arc -fvisibility=default -O2 \
    "${ARCHS_FLAGS[@]}" -isysroot "$SDK" -mmacosx-version-min="$MIN" \
    -I "$SRC/include" -I "$SRC/src" \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name "@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter" \
    "$SRC"/src/adapter/*.m "$SRC"/src/private/*.m "$SRC"/src/utility/*.m \
    -o "$BIN"

cat > "$FW/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
    <key>CFBundleIdentifier</key><string>com.ayush.Islet.MediaRemoteAdapter</string>
    <key>CFBundleName</key><string>MediaRemoteAdapter</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST

ln -sfh A "$FW/Versions/Current"
ln -sfh Versions/Current/MediaRemoteAdapter "$FW/MediaRemoteAdapter"
ln -sfh Versions/Current/Resources "$FW/Resources"

cp "$SRC/bin/mediaremote-adapter.pl" "$OUT/"

# Ad-hoc here; install.sh re-signs the whole app with a real identity afterwards.
codesign --force --sign - "$FW" >/dev/null
