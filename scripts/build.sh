#!/bin/bash
set -e

APP="speakfree.app"
VERSION=$(grep 'let version' Sources/OpenWisprLib/Version.swift | sed 's/.*"\(.*\)".*/\1/')
DMG="speakfree-${VERSION}.dmg"
SIGN_ID="Developer ID Application: Michael Morgenstern (AZ53Y7V4UZ)"
ENTITLEMENTS="$(dirname "$0")/speakfree.entitlements"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Vendored whisper.cpp + ggml binaries. Pinning to a known-good version
# (libwhisper 1.8.3 + ggml 0.9.5) avoids depending on transient brew state —
# specifically, brew's whisper-cpp 1.8.4 is ABI-incompatible with current ggml
# 0.10.0, so building against brew silently produces a binary that ggml_aborts
# at model load. See scripts/vendor/dylibs/README.md.
VENDOR_DIR="$(dirname "$0")/vendor/dylibs"

echo "Building speakfree v${VERSION}..."
swift build -c release

echo "Updating Info.plist version to ${VERSION}..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "$APP/Contents/Info.plist"

echo "Copying main binary..."
cp .build/release/speakfree "$APP/Contents/MacOS/speakfree"

echo "Bundling whisper-cli..."
mkdir -p "$APP/Contents/Frameworks"
cp "$VENDOR_DIR/whisper-cli" "$APP/Contents/MacOS/whisper-cli"

echo "Bundling Sparkle.framework..."
SPARKLE_FW=".build/arm64-apple-macosx/release/Sparkle.framework"
if [ ! -d "$SPARKLE_FW" ]; then
    SPARKLE_FW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
fi
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
cp -a "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

# Wipe stale dylibs (and any Dropbox conflicted-copy cruft) before bundling
# the pinned set, so we never accidentally ship an old/incompatible version.
find "$APP/Contents/Frameworks" -maxdepth 1 -type f -name '*.dylib' -delete
find "$APP/Contents/Frameworks" -maxdepth 1 -type l -name '*.dylib' -delete

# Bundle the pinned whisper.cpp + ggml dylibs from vendor.
for dylib in "$VENDOR_DIR"/*.dylib; do
    cp "$dylib" "$APP/Contents/Frameworks/"
done

# Create versioned symlinks so whisper-cli + libwhisper can find their deps by soname
for real_dylib in "$APP/Contents/Frameworks"/*.dylib; do
    basename=$(basename "$real_dylib")
    soname=$(echo "$basename" | sed 's/\([^0-9]*[0-9]*\)\.[0-9]*\.[0-9]*\.dylib$/\1.dylib/')
    if [ "$soname" != "$basename" ]; then
        ln -sf "$basename" "$APP/Contents/Frameworks/$soname"
    fi
done

# Fix rpaths so binaries find frameworks/dylibs inside the bundle.
# (Use add_rpath in a guarded form: it errors if the rpath already exists.)
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/speakfree" 2>/dev/null || true
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/whisper-cli" 2>/dev/null || true

# Re-point the speakfree binary's libwhisper reference to @rpath. Swift Package
# Manager links it against the dylib's LC_ID_DYLIB (an absolute brew path), so
# without this fixup the running binary loads brew's libwhisper at runtime
# instead of the bundled one, defeating the whole pinning scheme.
SPEAKFREE_BIN="$APP/Contents/MacOS/speakfree"
ORIG_WHISPER_REF=$(otool -L "$SPEAKFREE_BIN" | awk '/libwhisper\.1\.dylib/ {print $1; exit}')
if [ -n "$ORIG_WHISPER_REF" ] && [ "$ORIG_WHISPER_REF" != "@rpath/libwhisper.1.dylib" ]; then
    install_name_tool -change "$ORIG_WHISPER_REF" "@rpath/libwhisper.1.dylib" "$SPEAKFREE_BIN"
fi

echo "Signing..."
xattr -cr "$APP"
# Sign dylibs and whisper-cli first (no entitlements needed for these)
codesign --force --options runtime --sign "$SIGN_ID" "$APP/Contents/Frameworks/"*.dylib
codesign --force --options runtime --sign "$SIGN_ID" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
codesign --force --options runtime --sign "$SIGN_ID" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --sign "$SIGN_ID" "$APP/Contents/MacOS/whisper-cli"
# Sign the main app with entitlements (microphone + apple-events)
codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP"

echo "Building DMG..."
rm -f "$DMG"
create-dmg \
    --volname "speakfree" \
    --window-pos 200 120 \
    --window-size 560 340 \
    --background "scripts/dmg-background.png" \
    --icon-size 128 \
    --icon "speakfree.app" 140 170 \
    --hide-extension "speakfree.app" \
    --app-drop-link 420 170 \
    "$DMG" \
    "$APP"

echo "Notarizing..."
xcrun notarytool submit "$DMG" \
    --keychain-profile "speakfree-notary" \
    --wait

echo "Stapling..."
xcrun stapler staple "$DMG"

echo "Updating Sparkle appcast..."
SPARKLE_BIN="/opt/homebrew/Caskroom/sparkle/2.9.0/bin"
APPCAST="docs/appcast.xml"
DOWNLOAD_URL="https://github.com/definitelyreal/speakfree/releases/download/v${VERSION}/${DMG}"
DMG_SIZE=$(stat -f%z "$DMG")
SIGNATURE=$("$SPARKLE_BIN/sign_update" "$DMG" 2>/dev/null | grep "sparkle:edSignature" | sed 's/.*"\(.*\)".*/\1/')
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S %z")

# Build new appcast with this release at the top
cat > "$APPCAST" << APPCAST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>speakfree Updates</title>
    <link>https://definitelyreal.github.io/speakfree/</link>
    <description>Updates for speakfree</description>
    <language>en</language>
    <item>
      <title>speakfree v${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure
        url="${DOWNLOAD_URL}"
        type="application/octet-stream"
        sparkle:edSignature="${SIGNATURE}"
        length="${DMG_SIZE}" />
    </item>
  </channel>
</rss>
APPCAST_EOF

echo "Installing to /Applications..."
cp -a "$APP" /Applications/

echo "Done: $APP"
echo "Done: $DMG (signed, notarized, stapled)"
echo "Done: $APPCAST (Sparkle appcast updated)"
